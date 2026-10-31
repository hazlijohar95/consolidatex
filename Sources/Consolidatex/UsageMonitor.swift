import AccCore
import Foundation
import UserNotifications

/// Last-known usage and activity for every account, refreshed every 15 seconds from local files.
/// Every 5 minutes it also asks Codex for each Codex account's limits and, with live Claude usage on,
/// Anthropic for each Claude account's, storing answers where the status line and `acc ls` read too.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var readings: [String: Usage] = [:]
    @Published private(set) var lastActive: [String: Date] = [:]
    /// Claude Code accounts' output tokens and requests over the last 5 hours.
    @Published private(set) var activity: [String: TranscriptLog.Activity] = [:]
    @Published private(set) var identities: [String: Identity] = [:]
    /// The apps running sessions on each account now. Counts rather than processes, so a session
    /// that's replaced by a new process (the Agent SDK starts one per query) doesn't redraw the panel.
    @Published private(set) var running: [String: [AppCount]] = [:]
    /// Why the last live read of an account failed; shown beside its last good reading.
    @Published private(set) var problems: [String: String] = [:]
    /// A refresh someone asked for is running. Timer ticks don't set it, so they don't redraw the panel.
    @Published private(set) var spinning = false
    @Published var liveClaude: Bool {
        didSet {
            UserDefaults.standard.set(liveClaude, forKey: Keys.liveClaude)
            if liveClaude { refresh() } else { problems = problems.filter { registry.account(id: $0.key)?.tool != .claude } }
        }
    }

    var registry: Registry = .empty {
        didSet { if registry != oldValue { refresh() } }
    }

    /// The installed tools, as the app found them on the login shell's PATH.
    var runners: [Tool: Runner] = [:]

    /// Accounts that reached a limit, or came off one, since the previous refresh.
    struct LimitChanges {
        var capped: [String] = []
        var ready: [String] = []
    }

    /// Called after every refresh, so the app can act on limits; resets happen by the clock, not only on new readings.
    var onRefresh: ((LimitChanges, Date) -> Void)?
    let history: UsageHistory

    private let usages: Usages
    private var schedule: LiveUsage.Schedule
    /// Capped as of the previous refresh, to notice when one comes back.
    private var capped: Set<String>?
    private var sampledAt: [String: Date] = [:]
    private var prunedAt: [String: Date] = [:]
    private var logs: [String: TranscriptLog] = [:]
    /// Accounts whose login was read, including those with none to find (opencode, logged out).
    private var identitiesRead: Set<String> = []
    private var readingLocal = false
    private var fetching = false
    private var timer: Timer?

    private enum Keys {
        static let liveClaude = "liveClaudeUsage"
        static let schedule = "liveUsageSchedule"
    }

    init(store: RegistryStore) {
        let usageStore = UsageStore(registryStore: store)
        usages = Usages(store: usageStore)
        history = UsageHistory(usageStore: usageStore)
        liveClaude = UserDefaults.standard.bool(forKey: Keys.liveClaude)
        schedule = UserDefaults.standard.data(forKey: Keys.schedule)
            .flatMap { try? JSONDecoder().decode(LiveUsage.Schedule.self, from: $0) } ?? .init()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Worked on in the last 3 minutes.
    func isActive(_ account: Account, at now: Date) -> Bool {
        lastActive[account.id].map { now.timeIntervalSince($0) < 180 } ?? false
    }

    /// Reads what's on disk now, and asks the services for accounts that are due. `force` (the refresh
    /// button) skips the regular spacing of live reads but still honours a server Retry-After.
    func refresh(force: Bool = false) {
        if force { spinning = true }
        readLocal(force: force)
        fetchLive(force: force)
    }

    /// Usage files, activity and logins: cheap and local, so it never waits on the network. `force`
    /// rereads logins and looks for new transcripts now rather than within the minute.
    private func readLocal(force: Bool = false) {
        guard !readingLocal else { return }
        readingLocal = true
        let registry = self.registry, usages = self.usages, now = Date()
        // Logins rarely change and Claude Code's state file can run to megabytes, so only new accounts are read.
        let unread = registry.accounts.filter { force || !identitiesRead.contains($0.id) }
        identitiesRead.formUnion(unread.map(\.id))
        let logs = registry.accounts(for: .claude).map { ($0.id, self.logs[$0.id] ?? TranscriptLog(folder: $0.folder())) }
        let known = identities
        self.logs = Dictionary(uniqueKeysWithValues: logs)
        // History takes the tokens spent since each account's previous sample.
        let sampleFrom = logs.reduce(into: [String: Date]()) { due, entry in
            let last = sampledAt[entry.0]
            if now.timeIntervalSince(last ?? .distantPast) >= UsageHistory.spacing { due[entry.0] = last ?? now - UsageHistory.spacing }
        }
        // A sample counts every reply up to now, so an account with a reading to sample looks for new transcripts first.
        let complete = Set(sampleFrom.keys.filter { readings[$0] != nil })
        Task.detached {
            // One account at a time: the first read after launch goes through every transcript of
            // the last 5 hours, and in parallel the peaks would add up. Later reads are only new lines.
            var activity: [String: TranscriptLog.Activity] = [:]
            for (id, log) in logs { activity[id] = await log.activity(at: now, complete: force || complete.contains(id)) }
            var spent: [String: [Origin: Int]] = [:]
            // Up to `now`: a reply written while this read runs belongs to the next sample.
            for (id, log) in logs { if let since = sampleFrom[id] { spent[id] = await log.tokens(since: since, until: now) } }
            let readings = usages.all(registry)
            // Claude's comes from its transcripts, which TranscriptLog has just walked.
            let active = registry.accounts.reduce(into: [String: Date]()) { $0[$1.id] = activity[$1.id]?.lastWrite ?? Sessions.lastActive($1) }
            let identities = unread.reduce(into: [String: Identity]()) { $0[$1.id] = Identity.read($1) }
            // Claude desktop's sessions name their login, not a folder, so they find their account
            // among the logins already read.
            let running = Dictionary(grouping: RunningSessions.scan(registry, logins: {
                known.merging(identities) { $1 }.compactMapValues(\.login)
            }), by: \.accountID).mapValues(RunningSessions.byApp)
            await MainActor.run {
                if running != self.running { self.running = running }
                if activity != self.activity { self.activity = activity }
                if active != self.lastActive { self.lastActive = active }
                if !identities.isEmpty { self.identities.merge(identities) { $1 } }
                self.update(readings, spent: spent, at: now)
                self.readingLocal = false
                if !self.fetching { self.spinning = false }
            }
        }
    }

    /// Asks Codex and, with consent, Anthropic, for accounts whose reading is older than the spacing.
    private func fetchLive(force: Bool) {
        guard !fetching else { return }
        let now = Date(), codex = runners[.codex]
        // Codex asks OpenAI with its own login, so it needs no opt-in; Claude's read sends the login token.
        let askable = registry.accounts.filter { $0.tool == .claude ? liveClaude : $0.tool == .codex && codex != nil }
        let due = Set(schedule.due(askable.map(\.id), at: now, force: force))
        // A reading the status line or a session file wrote within the spacing is as good as asking.
        let live = askable.filter { due.contains($0.id) && (force || readings[$0.id].map { now.timeIntervalSince($0.recordedAt) >= LiveUsage.spacing } ?? true) }
        guard !live.isEmpty else { return }
        fetching = true
        let usages = self.usages
        Task.detached {
            let outcomes = await withTaskGroup(of: (String, LiveUsage.Outcome?).self) { group in
                for account in live { group.addTask { (account.id, await LiveUsage.fetch(account, runner: codex)) } }
                return await group.reduce(into: [String: LiveUsage.Outcome]()) { $0[$1.0] = $1.1 }
            }
            for case let (id, .reading(reading)) in outcomes { _ = try? usages.store.merge(reading, for: id, at: now) }
            await MainActor.run {
                for (id, outcome) in outcomes {
                    self.schedule.record(outcome, for: id, at: now)
                    self.problems[id] = switch outcome {
                    case .reading: nil
                    case .failed(let reason): reason
                    case .retryAfter(let seconds): self.readings[id] == nil ? "Anthropic is pacing usage checks; next in \(Int(seconds / 60) + 1) min" : nil
                    }
                }
                UserDefaults.standard.set(try? JSONEncoder().encode(self.schedule), forKey: Keys.schedule)
                self.fetching = false
                self.readLocal()
            }
        }
    }

    private func update(_ readings: [String: Usage], spent: [String: [Origin: Int]], at now: Date) {
        if readings != self.readings { self.readings = readings }
        let nowCapped = Set(readings.filter { $0.value.isCapped(at: now) }.keys)
        // The first refresh after launch has nothing to compare with, so it reports no changes.
        let changes = capped.map { LimitChanges(capped: Array(nowCapped.subtracting($0)), ready: Array($0.subtracting(nowCapped))) } ?? LimitChanges()
        capped = nowCapped
        record(readings, spent: spent, at: now)
        onRefresh?(changes, now)
    }

    /// A history sample per account every 15 minutes, for the weekly report.
    private func record(_ readings: [String: Usage], spent: [String: [Origin: Int]], at now: Date) {
        for (id, usage) in readings where now.timeIntervalSince(sampledAt[id] ?? .distantPast) >= UsageHistory.spacing {
            sampledAt[id] = now
            try? history.append(UsageHistory.Sample(usage, at: now, tokens: spent[id] ?? [:]), for: id)
            // The app can run for months, so old samples go once a day rather than once per launch.
            if now.timeIntervalSince(prunedAt[id] ?? .distantPast) >= 86_400 {
                prunedAt[id] = now
                try? history.prune(id, at: now)
            }
        }
    }
}
