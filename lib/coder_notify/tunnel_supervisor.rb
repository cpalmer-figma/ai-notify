require_relative "tunnel_planner"

module CoderNotify
  # Starts, watches and restarts one `coder ssh` reverse tunnel per enabled,
  # running workspace.
  #
  # Each tunnel runs `coder-notify-remote tunnel` on the workspace (a script
  # you installed by hand). It checks the tunnel works end to end, prints
  # READY, replays events that failed while the tunnel was down, reports the
  # live tmux panes, and then waits quietly. Its exit code tells us what went
  # wrong if it can't run (see EXIT_CODES).
  #
  # We keep the remote script's stdin open. When this service stops, stdin
  # closes, the script exits, and the SSH session and tunnel close with it.
  #
  # The tunnel sends no periodic heartbeat: in Coder, network traffic counts
  # as workspace activity, and a heartbeat would stop idle workspaces from
  # auto-stopping.
  class TunnelSupervisor
    # Mutable, because a tunnel's state changes over its life.
    Tunnel = Struct.new(:workspace, :handle, :state, :detail, :failures, :retry_at, :started_at,
                        keyword_init: true) do
      def running? = !handle.nil?
    end

    # Exit codes from `coder-notify-remote tunnel` (and the shell), mapped
    # to [state, explanation, seconds before retrying]. Anything else (for
    # example coder ssh's 1 or 255) is treated as a broken connection.
    EXIT_CODES = {
      3 => ["remote_not_configured", "~/.config/coder-notify/env is missing on the workspace; see README", 300],
      4 => ["token_rejected", "the Mac rejected this workspace's token; run bin/coder-notify token NAME and recopy it", 300],
      5 => ["port_conflict", "something else answers on the forwarded port on the workspace", 60],
      6 => ["remote_missing_tools", "curl or jq is missing on the workspace; see README", 300],
      127 => ["remote_not_installed", "~/.local/bin/coder-notify-remote is not installed on the workspace; see README", 300]
    }.freeze
    MAX_BACKOFF = 60
    # coder ssh waits forever if the agent is unreachable; give up after this.
    CONNECT_TIMEOUT = 120

    def initialize(config:, spawner: ProcessSpawner.new, clock: -> { Time.now.to_f }, logger: nil, on_change: -> {})
      @config = config
      @spawner = spawner
      @clock = clock
      @logger = logger
      @on_change = on_change
      @tunnels = {} # workspace id => Tunnel
      @mutex = Mutex.new
    end

    # Starts and stops tunnels so that reality matches the plan. Called on a
    # timer and after every discovery run.
    def reconcile(workspaces, enabled_ids)
      @mutex.synchronize do
        give_up_on_slow_connects
        plan = TunnelPlanner.plan(workspaces: workspaces, enabled_ids: enabled_ids, tunnels: @tunnels, now: @clock.call)
        plan.stop.each { |id| stop_tunnel(id) }
        plan.start.each { |workspace| start_tunnel(workspace) }
        @on_change.call if plan.start.any? || plan.stop.any?
      end
    end

    # { "state" => ..., "detail" => ... } for the menu, or nil if no tunnel.
    # While waiting to reconnect it also includes "retry_in" (seconds).
    def status(workspace_id)
      @mutex.synchronize do
        tunnel = @tunnels[workspace_id]
        next nil unless tunnel

        status = { "state" => tunnel.state, "detail" => tunnel.detail }
        status["retry_in"] = [(tunnel.retry_at - @clock.call).ceil, 0].max unless tunnel.running?
        status
      end
    end

    def stop_all
      @mutex.synchronize { @tunnels.keys.each { |id| stop_tunnel(id) } }
    end

    # The command for one tunnel. -R asks the workspace to listen on
    # remote_port and forward connections to our 127.0.0.1:port. Coder's -R
    # takes remote_port:local_address:local_port and always binds the
    # workspace side to 127.0.0.1, so nothing else on its network can use it.
    def command_for(workspace)
      [
        @config.coder_bin, "ssh",
        "--disable-autostart",   # never start a stopped workspace for us (default is to start it!)
        "--wait=no",             # don't wait for the workspace's startup script
        "--usage-app=disable",   # a monitoring tunnel is not you "using" the workspace
        "-R", "#{@config.remote_port}:127.0.0.1:#{@config.port}",
        workspace.ssh_target,    # e.g. "api-work.workspace": the main agent
        "--", "$HOME/.local/bin/coder-notify-remote tunnel" # run by the workspace's shell
      ]
    end

    private

    def start_tunnel(workspace)
      previous = @tunnels[workspace.id]
      tunnel = Tunnel.new(workspace: workspace, state: "connecting", detail: "starting coder ssh",
                          failures: previous ? previous.failures : 0, retry_at: 0, started_at: @clock.call)
      @tunnels[workspace.id] = tunnel
      @logger&.info("tunnel #{workspace.name}: starting")

      tunnel.handle = @spawner.spawn(
        command_for(workspace),
        on_line: ->(line) { line_received(workspace.id, tunnel, line) },
        on_error_line: ->(line) { error_line_received(workspace.id, line) },
        on_exit: ->(code) { exited(workspace.id, tunnel, code) }
      )
    rescue SystemCallError => e
      tunnel.handle = nil
      schedule_retry(tunnel, "error", "could not run coder: #{e.message}", backoff(tunnel))
    end

    def stop_tunnel(id)
      tunnel = @tunnels.delete(id)
      return unless tunnel&.handle

      @logger&.info("tunnel #{tunnel.workspace.name}: stopping")
      @spawner.stop(tunnel.handle)
    end

    # Kills tunnels stuck in "connecting" and schedules a retry.
    def give_up_on_slow_connects
      now = @clock.call
      @tunnels.each_value do |tunnel|
        next unless tunnel.running? && tunnel.state == "connecting" && now - tunnel.started_at > CONNECT_TIMEOUT

        @logger&.info("tunnel #{tunnel.workspace.name}: no READY after #{CONNECT_TIMEOUT}s, retrying")
        handle = tunnel.handle
        tunnel.handle = nil # mark as handled, so its exit callback is ignored
        @spawner.stop(handle)
        tunnel.failures += 1
        schedule_retry(tunnel, "reconnecting", "timed out connecting: #{tunnel.detail}", backoff(tunnel))
      end
    end

    # stdout from the remote script. "READY" means events can flow.
    def line_received(id, tunnel, line)
      @mutex.synchronize do
        next unless @tunnels[id].equal?(tunnel)

        if line.strip == "READY"
          tunnel.state = "connected"
          tunnel.detail = "tunnel verified"
          tunnel.failures = 0
          @logger&.info("tunnel #{tunnel.workspace.name}: connected")
          @on_change.call
        end
      end
    end

    # stderr from coder ssh or the remote script; kept for troubleshooting.
    def error_line_received(id, line)
      @mutex.synchronize do
        tunnel = @tunnels[id]
        @logger&.info("tunnel #{tunnel&.workspace&.name || id}: #{line}")
        tunnel.detail = line.strip[0, 200] if tunnel && !line.strip.empty? && tunnel.state != "connected"
      end
    end

    def exited(id, tunnel, code)
      @mutex.synchronize do
        # Ignore exits of tunnels we already stopped, replaced or timed out.
        next unless @tunnels[id].equal?(tunnel) && tunnel.running?

        tunnel.handle = nil
        state, detail, delay = EXIT_CODES[code]
        if state
          schedule_retry(tunnel, state, detail, delay)
        else
          tunnel.failures += 1
          last_error = tunnel.state == "connected" ? "connection lost" : tunnel.detail
          schedule_retry(tunnel, "reconnecting", "exit #{code.inspect}: #{last_error}", backoff(tunnel))
        end
        @logger&.info("tunnel #{tunnel.workspace.name}: exited #{code.inspect}, #{tunnel.state}")
        @on_change.call
      end
    end

    def schedule_retry(tunnel, state, detail, delay)
      tunnel.state = state
      tunnel.detail = detail
      tunnel.retry_at = @clock.call + delay
    end

    # 2, 4, 8, ... seconds, capped at MAX_BACKOFF.
    def backoff(tunnel) = [2**[tunnel.failures, 1].max, MAX_BACKOFF].min
  end

  # Runs a child process with pipes for stdin/stdout/stderr and reports its
  # output and exit through callbacks. Replaced by a fake in tests.
  class ProcessSpawner
    Handle = Data.define(:pid, :stdin)

    def spawn(argv, on_line:, on_error_line:, on_exit:)
      in_read, in_write = IO.pipe
      out_read, out_write = IO.pipe
      err_read, err_write = IO.pipe
      pid = Process.spawn(*argv, in: in_read, out: out_write, err: err_write)
      [in_read, out_write, err_write].each(&:close)

      Thread.new { each_line(out_read, on_line) }
      Thread.new { each_line(err_read, on_error_line) }
      Thread.new do
        _pid, status = Process.wait2(pid)
        on_exit.call(status.exitstatus)
      end
      Handle.new(pid: pid, stdin: in_write)
    end

    def stop(handle)
      handle.stdin.close unless handle.stdin.closed?
      Process.kill("TERM", handle.pid)
    rescue Errno::ESRCH
      # Already gone.
    end

    private

    def each_line(io, callback)
      io.each_line { |line| callback.call(line.chomp) }
    rescue IOError
      # Pipe closed while reading; the process is exiting.
    ensure
      io.close unless io.closed?
    end
  end
end
