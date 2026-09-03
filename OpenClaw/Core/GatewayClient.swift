import Foundation
import os

// MARK: - Protocol (Dependency Inversion)

/// Abstraction over gateway networking — ViewModels depend on this, not concrete types.
protocol GatewayClientProtocol: Sendable {
    func stats<Response: Decodable>(_ path: String) async throws -> Response
    func statsPost<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response
    func invoke<Body: Encodable, Response: Decodable>(_ body: Body) async throws -> Response
    func chatCompletion(_ request: ChatCompletionRequest, sessionKey: String) async throws -> ChatCompletionResponse
    func streamChat(message: String, sessionKey: String) -> AsyncThrowingStream<String, Error>
}

// MARK: - Implementation

/// Thread-safe gateway HTTP client. Configured with a base URL and token.
struct GatewayClient: GatewayClientProtocol, Sendable {
    private static let logger = Logger(subsystem: "co.uk.appwebdev.openclaw", category: "Gateway")

    private static let longRunningSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 900
        return URLSession(configuration: config)
    }()

    private let baseURL: URL
    private let token: String

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Convenience init from AccountStore. Reads actor-isolated state on the main actor.
    @MainActor
    init?(accountStore: AccountStore) {
        guard let url = accountStore.activeBaseURL(),
              let token = accountStore.activeToken() else { return nil }
        self.init(baseURL: url, token: token)
    }

    // MARK: - GET /stats/*

    func stats<Response: Decodable>(_ path: String) async throws -> Response {
        let (data, _) = try await request("GET", path: path)
        return try JSONDecoder.snakeCase.decode(Response.self, from: data)
    }

    // MARK: - POST /stats/*

    func statsPost<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        let (data, _) = try await request("POST", path: path, body: bodyData)
        return try JSONDecoder.snakeCase.decode(Response.self, from: data)
    }

    // MARK: - POST /tools/invoke

    func invoke<Body: Encodable, Response: Decodable>(_ body: Body) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        let (data, _) = try await request("POST", path: "tools/invoke", body: bodyData)
        let envelope = try JSONDecoder().decode(GatewayResponse.self, from: data)
        guard let text = envelope.result.content.first?.text,
              let jsonData = text.data(using: .utf8) else {
            throw GatewayError.emptyContent
        }
        do {
            return try JSONDecoder().decode(Response.self, from: jsonData)
        } catch {
            // Surface gateway business errors instead of a raw decode error.
            if let err = try? JSONDecoder().decode(GatewayToolErrorEnvelope.self, from: jsonData) {
                throw GatewayError.toolError(err.message)
            }
            // Log the raw JSON and decoding error for debugging
            let preview = String(text.prefix(500))
            Self.logger.error("Decode failed for \(String(describing: Response.self)): \(error.localizedDescription)\nRaw JSON: \(preview)")
            throw error
        }
    }

    // MARK: - POST /v1/chat/completions

    func chatCompletion(_ request: ChatCompletionRequest, sessionKey: String) async throws -> ChatCompletionResponse {
        let token = try requireToken()
        let url = try buildURL("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
        req.httpBody = try JSONEncoder().encode(request)

        Self.logger.debug("POST /v1/chat/completions (session: \(sessionKey))")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.longRunningSession.data(for: req)
        } catch is CancellationError {
            throw GatewayError.connectionLost
        } catch let urlError as URLError where urlError.code == .cancelled || urlError.code == .networkConnectionLost {
            throw GatewayError.connectionLost
        }

        try validateHTTPResponse(response, data: data, path: "v1/chat/completions")
        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    // MARK: - SSE streaming chat

    func streamChat(message: String, sessionKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let token = try requireToken()
                    let url = try buildURL("v1/chat/completions")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

                    let body = ChatCompletionRequest(system: "", user: message, model: "openclaw", stream: true)
                    req.httpBody = try JSONEncoder().encode(body)

                    Self.logger.debug("SSE /v1/chat/completions (session: \(sessionKey))")
                    let (bytes, response) = try await Self.longRunningSession.bytes(for: req)

                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let http = response as? HTTPURLResponse
                        continuation.finish(throwing: GatewayError.httpError(http?.statusCode ?? 0, body: "Stream failed"))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private helpers

    private func request(_ method: String, path: String, body: Data? = nil) async throws -> (Data, URLResponse) {
        let token = try requireToken()
        let url = try buildURL(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        Self.logger.debug("\(method) /\(path)")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTPResponse(response, data: data, path: path)
        return (data, response)
    }

    private func requireToken() throws -> String {
        guard !token.isEmpty else { throw GatewayError.noToken }
        return token
    }

    private func buildURL(_ path: String) throws -> URL {
        guard let url = URL(string: "\(baseURL.absoluteString)/\(path)") else { throw GatewayError.invalidResponse }
        return url
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else { throw GatewayError.invalidResponse }
        let isStatsPath = path.hasPrefix("stats/")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // The stats server always answers JSON. A bare 404 "Not Found" on /stats/* means the
            // request landed on the gateway — the proxy isn't splitting /stats to port 8765.
            if isStatsPath, http.statusCode == 404, !Self.looksLikeJSON(data) {
                Self.logger.error("/\(path) returned 404 non-JSON — stats server not routed")
                throw GatewayError.statsNotRouted(path: path, status: http.statusCode)
            }
            if let envelope = try? JSONDecoder().decode(GatewayErrorEnvelope.self, from: data), let err = envelope.error {
                throw GatewayError.serverError(http.statusCode, type: err.type, message: err.message)
            }
            throw GatewayError.httpError(http.statusCode, body: body)
        }
        // 200 with an HTML body on /stats/* is the gateway's web UI (SPA fallback), not stats JSON.
        // Without this check the caller sees "data couldn't be read because it isn't in the correct format".
        if isStatsPath, Self.looksLikeHTML(data, contentType: http.value(forHTTPHeaderField: "Content-Type")) {
            Self.logger.error("/\(path) returned HTML — stats server not routed (got gateway UI)")
            throw GatewayError.statsNotRouted(path: path, status: http.statusCode)
        }
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    private static func looksLikeHTML(_ data: Data, contentType: String?) -> Bool {
        if let ct = contentType?.lowercased(), ct.contains("text/html") { return true }
        guard let head = String(data: data.prefix(64), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<!doctype html") || head.contains("<html")
    }
}

private extension JSONDecoder {
    static let snakeCase: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
