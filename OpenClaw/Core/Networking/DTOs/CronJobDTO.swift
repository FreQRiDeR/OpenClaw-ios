import Foundation

struct CronJobListResponseDTO: Decodable, Sendable {
    let jobs: [CronJobDTO]
    let total: Int
}

/// Decodes a single cron job.
///
/// Supports **both** gateway response shapes:
/// - Nested:  `{id, name, enabled, schedule: {kind, expr, tz, everyMs}, state: {nextRunAtMs, lastRunAtMs, lastRunStatus, ...}, payload: {...}}`
/// - Flat:    `{id, name, enabled, scheduleKind, nextRunAtMs, lastRunStatus, ...}`  (current openclaw gateway)
struct CronJobDTO: Decodable, Sendable {
    let id: String
    let name: String
    let enabled: Bool
    let schedule: Schedule
    let state: State
    let payload: Payload?

    struct Payload: Decodable, Sendable {
        let model: String?
        let message: String?
    }

    struct Schedule: Decodable, Sendable {
        let kind: String
        let expr: String?
        let tz: String?
        let everyMs: Int?
    }

    struct State: Decodable, Sendable {
        let nextRunAtMs: Int?
        let lastRunAtMs: Int?
        let lastRunStatus: String?
        let consecutiveErrors: Int?
        let lastError: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, schedule, state, payload
        // Flat-shape keys (current gateway output)
        case scheduleKind
        case nextRunAtMs
        case lastRunAtMs
        case lastRunStatus
        case consecutiveErrors
        case lastError
        case model
        case message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)

        // Prefer the flat shape if present.
        if let kind = try c.decodeIfPresent(String.self, forKey: .scheduleKind) {
            // Flat: {scheduleKind, nextRunAtMs, lastRunStatus, ...}
            schedule = Schedule(
                kind: kind,
                expr: nil,
                tz: nil,
                everyMs: nil
            )
            state = State(
                nextRunAtMs: try c.decodeIfPresent(Int.self, forKey: .nextRunAtMs),
                lastRunAtMs: try c.decodeIfPresent(Int.self, forKey: .lastRunAtMs),
                lastRunStatus: try c.decodeIfPresent(String.self, forKey: .lastRunStatus),
                consecutiveErrors: try c.decodeIfPresent(Int.self, forKey: .consecutiveErrors),
                lastError: try c.decodeIfPresent(String.self, forKey: .lastError)
            )
            let model = try c.decodeIfPresent(String.self, forKey: .model)
            let message = try c.decodeIfPresent(String.self, forKey: .message)
            payload = (model != nil || message != nil) ? Payload(model: model, message: message) : nil
        } else {
            // Nested shape: {schedule: {...}, state: {...}, payload: {...}}
            schedule = try c.decode(Schedule.self, forKey: .schedule)
            state = try c.decode(State.self, forKey: .state)
            payload = try c.decodeIfPresent(Payload.self, forKey: .payload)
        }
    }
}
