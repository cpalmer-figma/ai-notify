import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var error: String?
    @Published var startupError: String?
    @Published var isRefreshing = false
    @Published var isStarting = false
    @Published var ownsService = false

    private let client: ServiceClient
    private let home: URL
    private var serviceProcess: Process?
    private var serviceLog: FileHandle?
    private var pollingTask: Task<Void, Never>?

    var displayError: String? { startupError ?? error }

    // #filePath points to this checkout when built locally in Xcode.
    private var repository: URL {
        if let path = UserDefaults.standard.string(forKey: "repositoryPath") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        home = URL(fileURLWithPath: NSString(string: env["CODER_NOTIFY_HOME"] ?? "~/.coder-notify").expandingTildeInPath)
        let port = Int(env["CODER_NOTIFY_PORT"] ?? "47290") ?? 47290
        client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)/")!, tokenURL: home.appendingPathComponent("menu-token"))
        AppDelegate.model = self
        pollingTask = Task { [weak self] in
            await self?.startServiceIfNeeded()
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { break }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing, !isStarting else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await client.snapshot()
            error = nil
            startupError = nil
        } catch {
            if !Task.isCancelled { self.error = "Cannot update the machine list. \(error.localizedDescription)" }
        }
    }

    func startServiceIfNeeded() async {
        guard !isStarting else { return }
        isStarting = true
        startupError = nil
        defer { isStarting = false }
        do {
            try await client.health()
            error = nil
            return // Reuse an existing service; never take ownership of it.
        } catch let failure as URLError where failure.code == .cannotConnectToHost {
            // Only a closed local port triggers a launch.
        } catch {
            self.startupError = error.localizedDescription
            return
        }
        if let process = serviceProcess, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: repository.appendingPathComponent("bin/coder-notify").path) else {
            startupError = "Choose the coder-notify project folder so the app can start its service."
            return
        }
        do {
            let launch = try ServiceLaunch(repository: repository)
            let logs = home.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let logURL = logs.appendingPathComponent("menubar-service.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            let process = Process()
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.environment = launch.environment
            process.currentDirectoryURL = launch.directory
            process.standardOutput = log
            process.standardError = log
            try process.run()
            serviceProcess = process
            serviceLog = log
            ownsService = true
            for _ in 0..<30 {
                try Task.checkCancellation()
                if !process.isRunning { throw StartupError.serviceExited(process.terminationStatus) }
                if (try? await client.health()) != nil { error = nil; return }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            throw StartupError.timeout
        } catch {
            if !Task.isCancelled { self.startupError = "\(error.localizedDescription) See the service log for details." }
            if serviceProcess?.isRunning != true {
                ownsService = false
                try? serviceLog?.close()
                serviceLog = nil
                serviceProcess = nil
            }
        }
    }

    func dismiss(_ key: String? = nil) async {
        do { try await client.dismiss(key: key); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func openDashboard() {
        do { NSWorkspace.shared.open(try client.dashboardURL()) }
        catch { self.error = error.localizedDescription }
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose the coder-notify project folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/coder-notify").path) else {
                error = "That folder does not contain bin/coder-notify."
                return
            }
            UserDefaults.standard.set(url.path, forKey: "repositoryPath")
            Task { await startServiceIfNeeded(); await refresh() }
        }
    }

    func openLog() { NSWorkspace.shared.open(home.appendingPathComponent("logs/menubar-service.log")) }

    func shutdown() {
        pollingTask?.cancel()
        if let process = serviceProcess, process.isRunning { process.terminate() }
        try? serviceLog?.close()
        ownsService = false
    }
}

private enum StartupError: LocalizedError {
    case serviceExited(Int32), timeout
    var errorDescription: String? {
        switch self {
        case .serviceExited(let status): return "The Ruby service exited with status \(status)."
        case .timeout: return "The Ruby service did not become ready in time."
        }
    }
}
