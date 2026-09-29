module CoderNotify
  # A Coder workspace as we care about it: identity plus enough status to
  # decide whether it can be monitored. Built from one entry of
  # `coder list --output json`.
  #
  # Data.define gives us an immutable value object with keyword arguments,
  # equality and #to_h for free.
  Workspace = Data.define(
    :id,            # stable Coder UUID; survives renames
    :name,          # e.g. "api-work"
    :owner,         # Coder username
    :build_status,  # latest_build.status: "running", "stopped", "starting", ...
    :agent_name,    # the main (top-level) agent, e.g. "workspace"
    :agent_status   # "connected", "connecting", "disconnected", "timeout" or nil
  ) do
    # Parses one workspace hash from `coder list --output json`.
    def self.from_coder_json(hash)
      build = hash.fetch("latest_build", {})
      agent = main_agent(build.fetch("resources", []))

      new(
        id: hash.fetch("id"),
        name: hash.fetch("name"),
        owner: hash["owner_name"],
        build_status: build["status"] || "unknown",
        agent_name: agent && agent["name"],
        agent_status: agent && agent["status"]
      )
    end

    # A workspace can have several agents. Devcontainer sub-agents have a
    # parent_id; the main agent (where our tmux sessions run) does not.
    def self.main_agent(resources)
      agents = resources.flat_map { |resource| resource["agents"] || [] }
      agents.find { |agent| agent["parent_id"].nil? }
    end

    # Rebuilds a Workspace from the hash we saved with #to_h.
    def self.from_h(hash) = new(**hash.transform_keys(&:to_sym))

    # One simple word for the menu and for tunnel decisions.
    def state
      case build_status
      when "running"
        # The VM is up, but we can only reach it through a connected agent.
        agent_status == "connected" ? "running" : "unreachable"
      when "pending", "starting" then "starting"
      when "stopping", "stopped", "canceling", "canceled" then "stopped"
      when "deleting", "deleted" then "deleting"
      else build_status # "failed" or anything new Coder adds
      end
    end

    def running? = state == "running"

    # Sessions on a workspace that is off cannot still be waiting for us.
    def off? = %w[stopped deleting failed].include?(state)

    # The `coder ssh` target, e.g. "api-work.workspace". Naming the agent
    # explicitly avoids landing in a devcontainer sub-agent by accident.
    def ssh_target = agent_name ? "#{name}.#{agent_name}" : name
  end
end
