import Foundation

struct Snapshot: Decodable {
    let attentionCount: Int
    let sessions: [AgentSession]
    let workspaces: [Workspace]
    let discovery: Discovery

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
    enum CodingKeys: String, CodingKey {
        case error
        case checkedAt = "checked_at"
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
