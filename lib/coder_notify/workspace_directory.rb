require "time"
require_relative "json_file"
require_relative "workspace"

module CoderNotify
  # Remembers the most recent successful workspace list and the latest
  # discovery error. If `coder list` fails we keep the old list (so tunnels
  # and the dashboard keep working) and just record the error.
  #
  # The list is saved to disk so the dashboard has something to show immediately
  # after a restart, before the first `coder list` finishes.
  class WorkspaceDirectory
    # What changed after applying a discovery result.
    Update = Data.define(:added, :removed)

    attr_reader :error

    def initialize(path:, clock: -> { Time.now })
      @path = path
      @clock = clock
      @mutex = Mutex.new
      load
    end

    def workspaces = @mutex.synchronize { @workspaces.values.sort_by(&:name) }
    def find(id) = @mutex.synchronize { @workspaces[id] }

    # Applies a WorkspaceDiscovery::Result. Returns an Update listing the
    # workspaces that appeared and disappeared (deleted in Coder).
    def apply(result)
      @mutex.synchronize do
        @checked_at = @clock.call

        if result.ok?
          previous = @workspaces
          @workspaces = result.workspaces.to_h { |workspace| [workspace.id, workspace] }
          @listed_at = @checked_at
          @error = nil
          update = Update.new(
            added: @workspaces.values.reject { |workspace| previous.key?(workspace.id) },
            removed: previous.values.reject { |workspace| @workspaces.key?(workspace.id) }
          )
        else
          # Keep @workspaces untouched: a temporary failure is not a deletion.
          @error = result.error
          update = Update.new(added: [], removed: [])
        end

        save
        update
      end
    end

    # The shape we both save to disk and return from GET /sessions.
    def to_h = @mutex.synchronize { snapshot }

    private

    def load
      data = JsonFile.read(@path, {})
      @workspaces = (data["workspaces"] || []).to_h do |hash|
        workspace = Workspace.from_h(hash)
        [workspace.id, workspace]
      end
      @error = data["error"]
      @checked_at = data["checked_at"] && Time.iso8601(data["checked_at"])
      @listed_at = data["listed_at"] && Time.iso8601(data["listed_at"])
    end

    def snapshot
      {
        "workspaces" => @workspaces.values.sort_by(&:name).map { |workspace| workspace.to_h.transform_keys(&:to_s) },
        "error" => @error,
        "checked_at" => @checked_at&.iso8601,
        "listed_at" => @listed_at&.iso8601
      }
    end

    def save = JsonFile.write(@path, snapshot)
  end
end
