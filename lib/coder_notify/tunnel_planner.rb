module CoderNotify
  # Decides which reverse tunnels should exist. It is a pure function of its
  # inputs (no processes, no clock reads), which keeps the rules easy to
  # read and easy to test:
  #
  #   * Only workspaces you enabled (have a token) get a tunnel.
  #   * Only running workspaces with a connected agent get a tunnel. We never
  #     start a stopped workspace just to monitor it.
  #   * A tunnel that exited waits for its retry time before starting again.
  #   * Tunnels for workspaces that stopped, became unreachable, were disabled
  #     or were deleted are stopped.
  module TunnelPlanner
    Plan = Data.define(:start, :stop)

    # workspaces  - current Workspace list (last known if discovery failed)
    # enabled_ids - workspace ids that have a token
    # tunnels     - workspace id => TunnelSupervisor::Tunnel (running or waiting to retry)
    # now         - current time (Float seconds)
    def self.plan(workspaces:, enabled_ids:, tunnels:, now:)
      wanted = workspaces.select { |ws| enabled_ids.include?(ws.id) && ws.running? }
      wanted_ids = wanted.map(&:id)

      start = wanted.select do |ws|
        tunnel = tunnels[ws.id]
        tunnel.nil? || (!tunnel.running? && now >= tunnel.retry_at)
      end
      stop = tunnels.keys.reject { |id| wanted_ids.include?(id) }

      Plan.new(start: start, stop: stop)
    end
  end
end
