import Foundation

struct ServiceClient {
    let baseURL: URL
    let tokenURL: URL
    let session: URLSession

    init(baseURL: URL, tokenURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.tokenURL = tokenURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        self.session = session ?? URLSession(configuration: configuration)
    }

    func health() async throws {
        let data = try await request("health", authenticated: false)
        struct Health: Decodable { let ok: Bool; let service: String }
        let health = try JSONDecoder().decode(Health.self, from: data)
        guard health.ok, health.service == "coder-notify" else { throw ClientError.wrongService }
    }

    func snapshot() async throws -> Snapshot {
        try await health()
        return try JSONDecoder().decode(Snapshot.self, from: await request("sessions"))
    }

    func dismiss(key: String? = nil) async throws {
        let body: [String: Any] = key.map { ["key": $0] } ?? ["all": true]
        _ = try await request("sessions/dismiss", body: JSONSerialization.data(withJSONObject: body))
    }

    func dashboardURL() throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.fragment = "token=\(try token())"
        return components.url!
    }

    private func token() throws -> String {
        guard let value = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { throw ClientError.missingToken }
        return value
    }

    private func request(_ path: String, authenticated: Bool = true, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if authenticated { request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.wrongService }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
        return data
    }
}

enum ClientError: LocalizedError {
    case missingToken, wrongService, http(Int)
    var errorDescription: String? {
        switch self {
        case .missingToken: return "No local access token yet. Start the service to create it."
        case .wrongService: return "The local port is occupied by a different service."
        case .http(let status): return "The local service returned HTTP \(status)."
        }
    }
}
