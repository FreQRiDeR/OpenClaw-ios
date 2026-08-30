import Foundation
import Observation

@Observable
@MainActor
final class SessionsViewModel {
    var sessions: [SessionEntry] = []
    var isLoading = false
    var error: Error?

    private let repository: SessionRepository

    var mainSession: SessionEntry? {
        sessions.first { if case .main = $0.kind { return true } else { return false } }
    }

    var subagents: [SessionEntry] {
        sessions
            .filter { if case .subagent = $0.kind { return true } else { return false } }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// All chat-capable sessions (main + subagents), most recently active first.
    /// These are what the user can select to open a live chat window.
    var activeSessions: [SessionEntry] {
        sessions
            .filter { session in
                switch session.kind {
                case .main, .subagent: return true
                case .cron: return false
                }
            }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func load() async {
        isLoading = true
        do {
            sessions = try await repository.fetchSessions(limit: 500)
            error = nil
        } catch {
            self.error = error
        }
        isLoading = false
    }
}
