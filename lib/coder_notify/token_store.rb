require "securerandom"
require "time"
require "rack/utils"
require_relative "json_file"

module CoderNotify
  # Per-workspace secrets. Each opted-in workspace gets its own random token,
  # which you copy onto that workspace during manual setup.
  #
  # A token does two jobs:
  #   1. Authentication - only holders of a token can post events.
  #   2. Identity - the token tells us WHICH workspace sent an event, so one
  #      workspace can't pretend to be another.
  # Having a token is also how a workspace counts as "enabled" for tunnels.
  #
  # The file is small, so we simply re-read it when it changes on disk. That
  # way `bin/coder-notify enable` works while the server is running.
  class TokenStore
    Entry = Data.define(:workspace_id, :workspace_name, :token, :created_at)

    def initialize(path:)
      @path = path
      @mutex = Mutex.new
      @mtime = nil
      @entries = {}
    end

    # Creates a token for the workspace (or returns the existing one).
    def enable(workspace, token: nil)
      raise ArgumentError, "invalid workspace token" if token && !token.match?(/\A[0-9a-f]{64}\z/)
      @mutex.synchronize do
        reload
        # A workspace deleted and re-created under the same name gets a new
        # Coder id; the old token is useless, so drop it.
        @entries.delete_if { |id, entry| entry.workspace_name == workspace.name && id != workspace.id }
        if @entries[workspace.id] && @entries[workspace.id].workspace_name != workspace.name
          @entries[workspace.id] = @entries[workspace.id].with(workspace_name: workspace.name)
        end
        entry = @entries[workspace.id] ||= Entry.new(
          workspace_id: workspace.id,
          workspace_name: workspace.name,
          token: token || SecureRandom.hex(32),
          created_at: Time.now.utc.iso8601
        )
        save
        entry
      end
    end

    def disable(workspace_id)
      @mutex.synchronize do
        reload
        removed = @entries.delete(workspace_id)
        save
        removed
      end
    end

    def entries = @mutex.synchronize { reload.values }
    def enabled?(workspace_id) = @mutex.synchronize { reload.key?(workspace_id) }

    # Finds the entry whose token matches. secure_compare takes the same time
    # whether or not the strings match, so response timing leaks nothing.
    def authenticate(token)
      return nil if token.nil? || token.empty?

      entries.find { |entry| Rack::Utils.secure_compare(entry.token, token) }
    end

    private

    # Re-reads the file only if it changed since we last looked.
    def reload
      mtime = File.exist?(@path) ? File.mtime(@path) : nil
      if mtime != @mtime
        data = JsonFile.read(@path, {})
        @entries = (data["workspaces"] || {}).transform_values do |hash|
          Entry.new(**hash.transform_keys(&:to_sym))
        end
        @mtime = mtime
      end
      @entries
    end

    def save
      JsonFile.write(@path, { "workspaces" => @entries.transform_values { |e| e.to_h.transform_keys(&:to_s) } })
      @mtime = File.mtime(@path)
    end
  end

  # The browser dashboard uses its own token for GET /sessions and "Dismiss".
  # Workspaces never see it, so a workspace can't read your other sessions
  # through its tunnel.
  module MenuToken
    def self.load_or_create(path)
      return File.read(path).strip if File.exist?(path)

      token = SecureRandom.hex(32)
      File.write(path, token + "\n", perm: 0o600)
      token
    end
  end
end
