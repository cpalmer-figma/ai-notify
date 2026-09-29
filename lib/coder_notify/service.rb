require "logger"
require "time"
require_relative "config"
require_relative "workspace_discovery"
require_relative "workspace_directory"
require_relative "session_store"
require_relative "token_store"
require_relative "notifier"
require_relative "change_worker"
require_relative "tunnel_supervisor"
require_relative "app"

module CoderNotify
  # Builds every piece of the Mac-side service, wires them together and runs
  # the background loops. config.ru creates one of these and hands #app to
  # Puma.
  #
  # Threads:
  #   * Puma request threads      - handle HTTP (see App)
  #   * discovery loop            - runs `coder list` every discovery_interval
  #   * tunnel loop               - starts/restarts tunnels every few seconds
  #   * change worker             - posts notifications and refreshes SwiftBar
  #   * per tunnel: output reader and exit waiter threads (ProcessSpawner)
  class Service
    TUNNEL_CHECK_INTERVAL = 3

    attr_reader :config, :sessions, :workspaces, :tokens, :menu_token, :tunnels, :logger

    def initialize(config: Config.new, logger: Logger.new($stdout), discovery: nil, notifier_backend: :default,
                   spawner: ProcessSpawner.new, menu_refresher: nil)
      @config = config
      @logger = logger
      config.ensure_home!

      @sessions = SessionStore.new(path: config.state_path)
      @workspaces = WorkspaceDirectory.new(path: File.join(config.home, "workspaces.json"))
      @tokens = TokenStore.new(path: config.tokens_path)
      @menu_token = MenuToken.load_or_create(config.menu_token_path)
      @discovery = discovery || WorkspaceDiscovery.new(coder_bin: config.coder_bin)
      @notifier = Notifier.new(backend: build_notifier_backend(notifier_backend), logger: logger)
      @notifier.adopt(@sessions.sessions)
      @menu_refresher = menu_refresher || MenuRefresher.new(plugin_name: config.swiftbar_plugin_name)
      @change_worker = ChangeWorker.new(logger: logger) do
        @notifier.sync(@sessions.sessions)
        @menu_refresher.refresh
      end
      @tunnels = TunnelSupervisor.new(config: config, spawner: spawner, logger: logger,
                                      on_change: -> { changed! })
    end

    def app = @app ||= App.with_context(self)

    def start
      @change_worker.start
      @threads = [
        every(config.discovery_interval) { discover },
        every(TUNNEL_CHECK_INTERVAL) { reconcile_tunnels }
      ]
      self
    end

    def stop
      @threads&.each(&:kill)
      @tunnels.stop_all
    end

    # Something the menu or notifications show has changed.
    def changed! = @change_worker.changed!

    # One discovery pass: run `coder list`, update the workspace list, and
    # forget sessions on workspaces that were deleted or are switched off.
    def discover
      result = @discovery.call
      update = @workspaces.apply(result)
      if result.ok?
        update.added.each { |ws| logger.info("discovered workspace #{ws.name} (#{ws.state})") }
        update.removed.each do |ws|
          logger.info("workspace #{ws.name} no longer exists; forgetting its sessions")
          @sessions.remove_workspace(ws.id)
        end
        @workspaces.workspaces.select(&:off?).each { |ws| @sessions.remove_workspace(ws.id) }
      else
        logger.warn("discovery failed, keeping last known list: #{result.error}")
      end
      reconcile_tunnels
      changed!
    end

    def reconcile_tunnels
      @tunnels.reconcile(@workspaces.workspaces, @tokens.entries.map(&:workspace_id))
    end

    # Everything the SwiftBar plugin needs, as returned by GET /sessions.
    def snapshot
      sessions = @sessions.sessions
      {
        "generated_at" => Time.now.utc.iso8601,
        "attention_count" => sessions.count(&:attention?),
        "sessions" => sessions.map { |session| session_json(session) },
        "workspaces" => @workspaces.workspaces.map { |workspace| workspace_json(workspace) },
        "discovery" => @workspaces.to_h.slice("error", "checked_at", "listed_at")
      }
    end

    private

    # Runs the block now and then every +seconds+, on its own thread.
    def every(seconds)
      Thread.new do
        loop do
          begin
            yield
          rescue StandardError => e
            logger.error("background loop: #{e.class}: #{e.message}")
          end
          sleep seconds
        end
      end
    end

    def session_json(session)
      session.to_h.transform_keys(&:to_s).merge(
        "attention" => session.attention?,
        "agent_label" => Labels.agent(session.agent),
        "reason_label" => session.waiting? ? Labels.reason(session.reason) : "Working",
        "waiting_since" => session.waiting_since_ms && Time.at(session.waiting_since_ms / 1000.0).utc.iso8601,
        "acknowledged_at" => session.acknowledged_at_ms && Time.at(session.acknowledged_at_ms / 1000.0).utc.iso8601
      )
    end

    # Combines Coder's view of a workspace with our monitoring status.
    def workspace_json(workspace)
      monitoring =
        if !@tokens.enabled?(workspace.id)
          { "state" => "not_enabled", "detail" => "not set up; see README (bin/coder-notify enable #{workspace.name})" }
        elsif !workspace.running?
          { "state" => "idle", "detail" => "workspace is #{workspace.state}; tunnel starts when it is running" }
        else
          @tunnels.status(workspace.id) || { "state" => "connecting", "detail" => "tunnel starting" }
        end
      workspace.to_h.transform_keys(&:to_s).merge("state" => workspace.state, "monitoring" => monitoring)
    end

    def build_notifier_backend(choice)
      return choice unless choice == :default
      return nil unless config.notifications

      backend = TerminalNotifierBackend.new(activate_bundle_id: config.activate_bundle_id)
      backend.available? ? backend : nil
    rescue LoadError => e
      logger.warn("notifications disabled: #{e.message}")
      nil
    end
  end
end
