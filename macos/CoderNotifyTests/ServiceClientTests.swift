import XCTest
import Foundation

final class ServiceClientTests: XCTestCase {
    private var directory: URL!
    private var tokenURL: URL!
    private var client: ServiceClient!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tokenURL = directory.appendingPathComponent("menu-token")
        try "test-menu-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:47290/")!, tokenURL: tokenURL,
                               session: URLSession(configuration: configuration))
    }

    override func tearDownWithError() throws {
        StubProtocol.handler = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testSnapshotIncludesDisabledAndStoppedMachines() async throws {
        StubProtocol.handler = { request in
            if request.url!.path == "/health" { return (200, #"{"ok":true,"service":"coder-notify"}"#) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-menu-token")
            return (200, #"{"attention_count":0,"sessions":[],"discovery":{},"workspaces":[{"id":"a","name":"alpha","state":"running","monitoring":{"state":"not_enabled"}},{"id":"b","name":"beta","state":"stopped","monitoring":{"state":"idle"}},{"id":"c","name":"gamma","state":"unreachable","monitoring":{"state":"idle"}}]}"#)
        }
        let snapshot = try await client.snapshot()
        XCTAssertEqual(snapshot.workspaces.count, 3)
        XCTAssertEqual(snapshot.workspaces[0].indicator, .running)
        XCTAssertEqual(snapshot.workspaces[0].monitoring.label, "not enabled")
        XCTAssertEqual(snapshot.workspaces[1].indicator, .stopped)
        XCTAssertEqual(snapshot.workspaces[2].indicator, .transitioning)
        XCTAssertEqual(snapshot.workspaces[0].browserURL.absoluteString, "https://coder.figdev.systems/@cpalmer/alpha")
    }

    func testDoesNotSendTokenToAnotherService() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/health")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, #"{"ok":true,"service":"another-app"}"#)
        }
        do { _ = try await client.snapshot(); XCTFail("Must reject a different service") }
        catch ClientError.wrongService { }
    }

    func testMissingTokenCannotDismiss() async throws {
        try FileManager.default.removeItem(at: tokenURL)
        StubProtocol.handler = { _ in XCTFail("Must not send an unauthenticated request"); return (200, "{}") }
        do { try await client.dismiss(); XCTFail("Must require a token") }
        catch ClientError.missingToken { }
    }

    func testDismissUsesAuthenticatedPost() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url!.path, "/sessions/dismiss")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-menu-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, #"{"result":"applied"}"#)
        }
        try await client.dismiss(key: "workspace|%1|claude|session")
    }

    func testDashboardAuthenticationUsesFragmentNotQuery() throws {
        let url = try client.dashboardURL()
        XCTAssertNil(url.query)
        XCTAssertEqual(url.fragment, "token=test-menu-token")
        XCTAssertEqual(url.host, "127.0.0.1")
    }

    func testServiceLaunchFromXcodeFindsProjectRubyAndCoderWithMinimalPath() throws {
        try "3.4.7\n".write(to: directory.appendingPathComponent(".ruby-version"), atomically: true, encoding: .utf8)
        let home = URL(fileURLWithPath: "/Users/test")
        let ruby = "/Users/test/.rbenv/versions/3.4.7/bin/ruby"
        let launch = try ServiceLaunch(repository: directory, userHome: home,
                                       environment: ["PATH": "/usr/bin:/bin"],
                                       isExecutable: { [ruby, "/usr/bin/ruby", "/usr/local/bin/coder"].contains($0) })
        XCTAssertEqual(launch.executableURL.path, ruby)
        XCTAssertEqual(launch.arguments, ["-EUTF-8", directory.appendingPathComponent("bin/coder-notify").path, "server"])
        XCTAssertEqual(launch.directory, directory)
        XCTAssertEqual(launch.environment["CODER_BIN"], "/usr/local/bin/coder")
        XCTAssertEqual(launch.environment["LC_ALL"], "en_US.UTF-8")
    }

    func testServiceLaunchDoesNotSilentlyFallBackToSystemRuby() throws {
        try "3.4.7\n".write(to: directory.appendingPathComponent(".ruby-version"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServiceLaunch(repository: directory, userHome: directory,
                                               environment: ["PATH": "/usr/bin:/bin"],
                                               isExecutable: { $0 == "/usr/bin/ruby" })) { error in
            XCTAssertTrue(error.localizedDescription.contains("Ruby 3.4.7 was not found"))
        }
    }

    func testServiceLaunchSupportsExplicitRubyAndPreservesServiceSettings() throws {
        try "3.4.7\n".write(to: directory.appendingPathComponent(".ruby-version"), atomically: true, encoding: .utf8)
        let env = ["CODER_NOTIFY_RUBY": "/custom/ruby", "CODER_BIN": "/custom/coder",
                   "CODER_NOTIFY_HOME": "/custom/state", "CODER_NOTIFY_PORT": "47300"]
        let launch = try ServiceLaunch(repository: directory, environment: env, isExecutable: { $0 == "/custom/ruby" })
        XCTAssertEqual(launch.executableURL.path, "/custom/ruby")
        for (key, value) in env { XCTAssertEqual(launch.environment[key], value) }
    }
}

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (status, json) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
