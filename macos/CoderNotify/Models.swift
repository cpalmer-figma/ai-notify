import Foundation

struct Snapshot: Decodable {
    let attentionCount: Int
    let sessions: [AgentSession]
    let workspaces: [Workspace]
    let discovery: Discovery

    var creditsUsed: Int { workspaces.reduce(0) { $0 + $1.creditsUsed } }
    var creditsEstimated: Bool { workspaces.contains { $0.usesEstimatedCredits } }
    static let creditLimit = 400

    enum CodingKeys: String, CodingKey {
        case attentionCount = "attention_count"
        case sessions, workspaces, discovery
    }
}

struct Workspace: Decodable, Identifiable {
    let id: String
    let name: String
    let state: String
    let monitoring: Monitoring
    let owner: String?
    let dailyCost: Int?
    let buildStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, name, state, monitoring, owner
        case dailyCost = "daily_cost"
        case buildStatus = "build_status"
    }

    // An unreachable agent still has an allocated machine. Keep counting a
    // stopping machine until discovery confirms that it has stopped.
    var usesEstimatedCredits: Bool {
        dailyCost == nil && ["running", "unreachable", "pending", "starting", "stopping"].contains(buildStatus ?? state)
    }

    var creditsUsed: Int { dailyCost.map { max(0, $0) } ?? (usesEstimatedCredits ? 30 : 0) }

    var browserURL: URL {
        URL(string: "https://coder.figdev.systems")!
            .appendingPathComponent("@\(owner ?? "cpalmer")")
            .appendingPathComponent(name)
    }

    var indicator: StatusIndicator {
        switch state {
        case "running": return .running
        case "stopped", "failed", "deleting": return .stopped
        case "starting", "unreachable": return .transitioning
        default: return .unknown
        }
    }
}

enum StatusIndicator { case running, stopped, transitioning, unknown }

struct Monitoring: Decodable {
    let state: String
    let detail: String?
    var label: String { state.replacingOccurrences(of: "_", with: " ") }
}

struct Discovery: Decodable {
    let error: String?
    let checkedAt: String?
    let listedAt: String?
    enum CodingKeys: String, CodingKey {
        case error
        case checkedAt = "checked_at"
        case listedAt = "listed_at"
    }
}

struct AgentSession: Decodable, Identifiable {
    let key: String
    let attention: Bool
    let status: String
    let agentLabel: String
    let workspaceName: String
    let paneLabel: String?
    let paneID: String
    let reasonLabel: String
    var id: String { key }
    var activityLabel: String { attention ? "Needs attention" : status == "waiting" ? "Seen" : "Working" }

    enum CodingKeys: String, CodingKey {
        case key, attention, status
        case agentLabel = "agent_label"
        case workspaceName = "workspace_name"
        case paneLabel = "pane_label"
        case paneID = "pane_id"
        case reasonLabel = "reason_label"
    }
}
