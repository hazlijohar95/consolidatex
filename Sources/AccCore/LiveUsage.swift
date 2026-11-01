import Foundation

/// Usage asked of the tool's service now, rather than read from what the tool last wrote: the only
/// way an idle account gets current numbers. Claude Code's comes from Anthropic's usage endpoint,
/// Codex's from Codex itself. Each service answers an account only every few minutes.
public enum LiveUsage {
    public enum Outcome: Equatable, Sendable {
        case reading(Usage)
        case retryAfter(TimeInterval)
        /// The login's access token ran out. The tool renews it the next time the account is used, so
        /// the account is still logged in and its last reading stands until then.
        case tokenExpired
        case failed(String)
    }

    public static let spacing: TimeInterval = 300

    /// Why a live read brought no reading, and when. A reading recorded after it answers it: the status
    /// line's, for one, once the account is used again, which also renews an expired token.
    public struct Miss: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case tokenExpired
            case failed(String)
        }

        public let reason: Reason
        public let at: Date

        public init(_ reason: Reason, at: Date) {
            self.reason = reason
            self.at = at
        }

        public func isAnswered(by reading: Usage?) -> Bool { reading.map { $0.recordedAt > at } ?? false }
    }

    /// Nil for a tool with no live source (opencode).
    public static func fetch(_ account: Account, runner: Runner?) async -> Outcome? {
        switch account.tool {
        case .claude:
            return await ClaudeUsageAPI.fetch(account)
        case .codex:
            guard let runner else { return .failed("codex is not installed") }
            return await offPool { CodexSupport.liveUsage(runner, account) }
        case .opencode:
            return nil
        }
    }

    /// Runs blocking work (waiting on a process or a keychain prompt) on a dispatch thread, so it
    /// doesn't hold one of Swift concurrency's few cooperative threads for seconds.
    public static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: work()) } }
    }

    /// When each account may be asked next. Persisted by the caller, so relaunching can't skip a Retry-After.
    public struct Schedule: Codable, Equatable, Sendable {
        /// The regular spacing between reads.
        var next: [String: Date] = [:]
        /// A server Retry-After, which even a manual refresh honours.
        var blocked: [String: Date] = [:]

        public init() {}

        /// The accounts to ask now: due, and with no reading or a window read `spacing` ago or more.
        /// Claude Code's status line keeps an account's shared windows fresh while it's in use, but
        /// not its per-model ones. `force` asks every account that isn't waiting out a Retry-After.
        public func toAsk(_ ids: [String], readings: [String: Usage], at now: Date, force: Bool = false) -> [String] {
            due(ids, at: now, force: force).filter { id in
                force || readings[id].map { now.timeIntervalSince($0.oldestRead) >= LiveUsage.spacing } ?? true
            }
        }

        func due(_ ids: [String], at now: Date, force: Bool = false) -> [String] {
            ids.filter { ((force ? blocked : next)[$0] ?? .distantPast) <= now }
        }

        public mutating func record(_ outcome: Outcome, for id: String, at now: Date) {
            switch outcome {
            case .reading, .tokenExpired, .failed:
                next[id] = now + LiveUsage.spacing
            case .retryAfter(let seconds):
                blocked[id] = now + seconds
                next[id] = now + max(seconds, LiveUsage.spacing)
            }
        }
    }
}
