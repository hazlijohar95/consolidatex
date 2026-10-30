import Foundation

/// Usage asked of the tool's service now, rather than read from what the tool last wrote: the only
/// way an idle account gets current numbers. Claude Code's comes from Anthropic's usage endpoint,
/// Codex's from Codex itself. Each service answers an account only every few minutes.
public enum LiveUsage {
    public enum Outcome: Equatable, Sendable {
        case reading(Usage)
        case retryAfter(TimeInterval)
        case failed(String)
    }

    public static let spacing: TimeInterval = 300

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
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in DispatchQueue.global().async { done.resume(returning: work()) } }
    }

    /// When each account may be asked next. Persisted by the caller, so relaunching can't skip a Retry-After.
    public struct Schedule: Codable, Equatable, Sendable {
        /// The regular spacing between reads.
        var next: [String: Date] = [:]
        /// A server Retry-After, which even a manual refresh honours.
        var blocked: [String: Date] = [:]

        public init() {}

        public func due(_ ids: [String], at now: Date, force: Bool = false) -> [String] {
            ids.filter { ((force ? blocked : next)[$0] ?? .distantPast) <= now }
        }

        public mutating func record(_ outcome: Outcome, for id: String, at now: Date) {
            switch outcome {
            case .reading, .failed:
                next[id] = now + LiveUsage.spacing
            case .retryAfter(let seconds):
                blocked[id] = now + seconds
                next[id] = now + max(seconds, LiveUsage.spacing)
            }
        }
    }
}
