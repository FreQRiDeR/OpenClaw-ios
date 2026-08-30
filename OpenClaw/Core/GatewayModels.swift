import Foundation

/// App-level constants derived from the active account.
/// Falls back to "orchestrator" if no account is active (should not happen in normal use).
@MainActor
enum AppConstants {
    static var account: GatewayAccount?

    static var agentId: String { account?.agentId ?? "orchestrator" }
    static var workspaceRoot: String { account?.workspaceRoot ?? "~/.openclaw/workspace/orchestrator/" }
}

/// Well-known session keys — derived from the active account's agentId.
@MainActor
enum SessionKeys {
    static var main: String { AppConstants.account?.sessionKeyMain ?? "agent:orchestrator:main" }
    static var cronPrefix: String { AppConstants.account?.sessionKeyCronPrefix ?? "agent:orchestrator:cron:" }
    static var subagentPrefix: String { AppConstants.account?.sessionKeySubagentPrefix ?? "agent:orchestrator:subagent:" }
}

// MARK: - Gateway Response Wrapper

/// Actual envelope: {"ok":true,"result":{"content":[{"type":"text","text":"<json string>"}]}}
struct GatewayResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct Content: Decodable, Sendable {
            let type: String
            let text: String
        }
        let content: [Content]
    }
    let ok: Bool
    let result: Result
}

// MARK: - Gateway Tool Request

struct GatewayToolRequest: Encodable, Sendable {
    let tool = "gateway"
    let args: Args

    struct Args: Encodable, Sendable {
        let action: String
    }
}

// MARK: - Error Types

struct GatewayErrorEnvelope: Decodable, Sendable {
    struct ErrorDetail: Decodable, Sendable {
        let type: String
        let message: String
    }
    let ok: Bool
    let error: ErrorDetail?
}

/// Business-level error surfaced inside a successful /tools/invoke envelope,
/// e.g. {"status":"forbidden","error":"..."}.
struct GatewayToolErrorEnvelope: Decodable, Sendable {
    let status: String?
    let error: String
    var message: String {
        status.map { "\($0): \(error)" } ?? error
    }
}

enum GatewayError: LocalizedError {
    case noToken
    case noBaseURL
    case invalidResponse
    case httpError(Int, body: String)
    case serverError(Int, type: String, message: String)
    case emptyContent
    case connectionLost
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No authentication token. Tap Configure to add your Bearer token."
        case .noBaseURL:
            return "No gateway URL configured. Go to Settings to configure your gateway."
        case .invalidResponse:
            return "Invalid response from gateway."
        case .httpError(let code, let body):
            return "Gateway HTTP \(code). Response: \(body.isEmpty ? "(empty)" : body)"
        case .serverError(let code, _, let message):
            return "Gateway HTTP \(code): \(message)"
        case .emptyContent:
            return "Gateway returned an empty response."
        case .connectionLost:
            return "Connection lost — the agent is still running on the server. Check back shortly."
        case .toolError(let message):
            return "Gateway tool error: \(message)"
        }
    }
}

// MARK: - Gateway Command Response

/// Response from a gateway tool command (e.g. restart).
struct GatewayCommandResponse: Decodable, Sendable {
    let message: String?
    let text: String?
}
