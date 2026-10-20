import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Coder Notify").font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.isRefreshing || model.isStarting { ProgressView().controlSize(.regular) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }.padding()
            CreditUsageView(snapshot: model.snapshot, isStale: model.displayError != nil)
                .padding(.horizontal)
                .padding(.bottom)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.displayError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(.orange)
                            if model.snapshot != nil { Text("Showing the last known machine list.").font(.system(size: 14)).foregroundStyle(.secondary) }
                            HStack {
                                Button("Retry service") { Task { await model.startServiceIfNeeded(); await model.refresh() } }
                                Button("View log", action: model.openLog)
                            }.controlSize(.regular)
                        }
                    }
                    HStack {
                        Text("Machines").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("\(model.snapshot?.workspaces.count ?? 0)").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    if let snapshot = model.snapshot {
                        ForEach(snapshot.workspaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { workspace in
                            Link(destination: workspace.browserURL) {
                                WorkspaceRow(workspace: workspace)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(workspace.name) in Coder")
                        }
                        if snapshot.workspaces.isEmpty { Text("No Coder machines found.").font(.system(size: 14)).foregroundStyle(.secondary) }
                        if let error = snapshot.discovery.error {
                            Label("Discovery failed: \(error)", systemImage: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(.orange)
                        }
                        Divider()
                        HStack {
                            Text("Agent activity").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            if snapshot.attentionCount > 0 {
                                Button("Dismiss all") { Task { await model.dismiss() } }.controlSize(.regular)
                            }
                        }
                        if snapshot.sessions.isEmpty {
                            Text("No agent activity reported yet. Machine status works already; agent alerts need a one-time setup on each workspace.")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.sessions.sorted { $0.attention && !$1.attention }) { session in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(session.agentLabel) · \(session.workspaceName)").font(.system(size: 16, weight: .medium))
                                    Text("\(session.paneLabel ?? session.paneID) · \(session.activityLabel)").font(.system(size: 14)).foregroundStyle(.secondary)
                                    Text(session.reasonLabel).font(.system(size: 14)).foregroundStyle(session.attention ? .primary : .secondary)
                                }
                                Spacer()
                                if session.attention {
                                    Button("Dismiss") { Task { await model.dismiss(session.key) } }.controlSize(.regular)
                                }
                            }
                            .contextMenu {
                                Button("Copy tmux target") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(session.paneLabel ?? session.paneID, forType: .string)
                                }
                            }
                        }
                    } else {
                        Text(model.isStarting ? "Starting the local service…" : "Waiting for the local service…")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }.padding()
            }.frame(height: 420)
            Divider()
            HStack {
                Button("Dashboard", action: model.openDashboard).disabled(model.snapshot == nil)
                Menu {
                    Button("Choose project folder…", action: model.chooseRepository)
                    Button("View service log", action: model.openLog)
                    Text(model.ownsService ? "Service stops when this app quits" : "Using an existing service")
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
            }.controlSize(.regular).padding()
        }.frame(width: 460)
    }
}

private struct CreditUsageView: View {
    let snapshot: Snapshot?
    let isStale: Bool

    private var hasUsage: Bool {
        guard let snapshot else { return false }
        return snapshot.discovery.listedAt != nil || !snapshot.workspaces.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Coder credits").fontWeight(.medium)
                Spacer()
                if hasUsage, let snapshot {
                    Text("\(snapshot.creditsUsed) / \(Snapshot.creditLimit)")
                        .monospacedDigit()
                } else {
                    Text("— / \(Snapshot.creditLimit)").foregroundStyle(.secondary)
                }
            }.font(.system(size: 14))
            ProgressView(value: hasUsage ? Double(min(snapshot?.creditsUsed ?? 0, Snapshot.creditLimit)) : 0,
                         total: Double(Snapshot.creditLimit))
                .progressViewStyle(.linear)
                .tint((snapshot?.creditsUsed ?? 0) >= Snapshot.creditLimit ? .orange : .accentColor)
                .accessibilityLabel("Coder credits used")
                .accessibilityValue(hasUsage ? "\(snapshot?.creditsUsed ?? 0) of \(Snapshot.creditLimit) credits" : "Usage unavailable")
            if !hasUsage {
                Text("Waiting for workspace usage…").foregroundStyle(.secondary)
            } else if isStale || snapshot?.discovery.error != nil {
                Text("Last known usage\(snapshot?.creditsEstimated == true ? " · Estimated at 30 credits per active box" : "")")
                    .foregroundStyle(.secondary)
            } else if snapshot?.creditsEstimated == true {
                Text("Estimated at 30 credits per active box").foregroundStyle(.secondary)
            }
        }.font(.system(size: 12))
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    private var color: Color {
        switch workspace.indicator {
        case .running: return .green
        case .stopped: return .red
        case .transitioning: return .yellow
        case .unknown: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 14, height: 14).padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(workspace.name).font(.system(size: 16, weight: .medium))
                    Spacer()
                    Text(workspace.state.capitalized).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Text("Notifications: \(workspace.monitoring.label)").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }.help(workspace.monitoring.detail ?? workspace.state)
    }
}
