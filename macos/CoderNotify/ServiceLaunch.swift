import Foundation

// Xcode's environment does not necessarily include the user's shell setup.
// Resolve the project Ruby explicitly rather than relying on /usr/bin/env ruby.
struct ServiceLaunch {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL

    init(repository: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment inherited: [String: String] = ProcessInfo.processInfo.environment,
         isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) throws {
        let version = try String(contentsOf: repository.appendingPathComponent(".ruby-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String]
        if let override = inherited["CODER_NOTIFY_RUBY"], !override.isEmpty {
            candidates = [NSString(string: override).expandingTildeInPath]
        } else {
            candidates = [
                userHome.appendingPathComponent(".rbenv/versions/\(version)/bin/ruby").path,
                userHome.appendingPathComponent(".local/share/mise/installs/ruby/\(version)/bin/ruby").path,
                userHome.appendingPathComponent(".asdf/installs/ruby/\(version)/bin/ruby").path,
                userHome.appendingPathComponent(".rbenv/shims/ruby").path
            ]
            candidates += (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
                .filter { !$0.isEmpty && !["/usr/bin", "/bin"].contains($0) }
                .map { URL(fileURLWithPath: $0).appendingPathComponent("ruby").path }
        }
        guard let ruby = candidates.first(where: isExecutable) else {
            throw LaunchError.missingRuby(version)
        }
        executableURL = URL(fileURLWithPath: ruby)
        arguments = ["-EUTF-8", repository.appendingPathComponent("bin/coder-notify").path, "server"]
        directory = repository
        var environment = inherited
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        let paths = [executableURL.deletingLastPathComponent().path,
                     userHome.appendingPathComponent(".local/bin").path,
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = paths.joined(separator: ":")
        if environment["CODER_BIN"] == nil, let coder = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("coder").path }).first(where: isExecutable) {
            environment["CODER_BIN"] = coder
        }
        self.environment = environment
    }
}

private enum LaunchError: LocalizedError {
    case missingRuby(String)
    var errorDescription: String? {
        switch self {
        case .missingRuby(let version):
            return "Ruby \(version) was not found. Install the project Ruby or set CODER_NOTIFY_RUBY to its executable in the Xcode scheme."
        }
    }
}
