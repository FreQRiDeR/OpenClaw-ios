import Foundation

// MARK: - Cron / Automations tool name

/// OpenClaw renamed the scheduler CLI from `cron` to `automations` (with `cron` kept as an
/// alias). The *gateway tool* name may follow. We try the remembered name first and, on a
/// `not_found` tool error, flip to the other spelling and retry once — so one build works
/// against both old and new gateways.
actor CronToolName {
    static let shared = CronToolName()
    static let candidates = ["cron", "automations"]
    private(set) var current = candidates[0]

    func alternate() -> String {
        current = Self.candidates.first { $0 != current } ?? current
        return current
    }
}

/// A `/tools/invoke` body whose tool name can be swapped between `cron` and `automations`.
protocol CronToolBody: Encodable, Sendable {
    func withTool(_ name: String) -> Self
}

extension GatewayClientProtocol {
    /// Invoke a cron/automations tool, transparently retrying with the other tool name if the
    /// gateway reports the current one as unknown.
    func invokeCron<Body: CronToolBody, Response: Decodable>(_ body: Body) async throws -> Response {
        let name = await CronToolName.shared.current
        do {
            return try await invoke(body.withTool(name))
        } catch GatewayError.serverError(_, let type, _) where type == "not_found" {
            let other = await CronToolName.shared.alternate()
            return try await invoke(body.withTool(other))
        }
    }
}

// MARK: - Request bodies

struct CronToolRequest: CronToolBody {
    var tool = CronToolName.candidates[0]
    let args: Input

    struct Input: Encodable, Sendable {
        let action: String
        let includeDisabled: Bool?
    }

    init(args: Input) {
        self.args = args
    }

    func withTool(_ name: String) -> Self { var c = self; c.tool = name; return c }
}

struct CronJobToolRequest: CronToolBody {
    var tool = CronToolName.candidates[0]
    let args: Args

    struct Args: Encodable, Sendable {
        let action: String
        let jobId: String
    }

    func withTool(_ name: String) -> Self { var c = self; c.tool = name; return c }
}

struct CronRunsToolRequest: CronToolBody {
    var tool = CronToolName.candidates[0]
    let args: Args

    struct Args: Encodable, Sendable {
        let action = "runs"
        let jobId: String
        let limit: Int
        let offset: Int
    }

    func withTool(_ name: String) -> Self { var c = self; c.tool = name; return c }
}

struct CronUpdateToolRequest: CronToolBody {
    var tool = CronToolName.candidates[0]
    let args: Args

    func withTool(_ name: String) -> Self { var c = self; c.tool = name; return c }

    struct Args: Encodable, Sendable {
        let action = "update"
        let jobId: String
        let patch: Patch
    }

    struct Patch: Encodable, Sendable {
        let enabled: Bool
    }
}

struct SessionListToolRequest: Encodable, Sendable {
    let tool = "sessions_list"
    let args: Args

    struct Args: Encodable, Sendable {
        let limit: Int
    }
}

struct SessionHistoryToolRequest: Encodable, Sendable {
    let tool = "sessions_history"
    let args: Args

    struct Args: Encodable, Sendable {
        let sessionKey: String
        let limit: Int
        let includeTools: Bool
    }
}
