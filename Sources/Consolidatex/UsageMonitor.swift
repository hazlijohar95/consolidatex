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

    private let usages: Usages
    private var schedule: LiveUsage.Schedule
    /// Capped as of the previous refresh, to notice when one comes back.
    private var capped: Set<String> = []
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
        usages = Usages(store: UsageStore(registryStore: store))
        liveClaude = UserDefaults.standard.bool(forKey: Keys.liveClaude)
        schedule = UserDefaults.standard.data(forKey: Keys.schedule)
            .flatMap { try? JSONDecoder().decode(LiveUsage.Schedule.self, from: $0) } ?? .init()
        ReadyNotice.prepare()
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
        readLocal(rereadIdentities: force)
        fetchLive(force: force)
    }

    /// Usage files, activity and logins: cheap and local, so it never waits on the network.
    private func readLocal(rereadIdentities: Bool = false) {
        guard !readingLocal else { return }
        readingLocal = true
        let registry = self.registry, usages = self.usages, now = Date()
        // Logins rarely change and Claude Code's state file can run to megabytes, so only new accounts are read.
        let unread = registry.accounts.filter { rereadIdentities || !identitiesRead.contains($0.id) }
        identitiesRead.formUnion(unread.map(\.id))
        let logs = registry.accounts(for: .claude).map { ($0.id, self.logs[$0.id] ?? TranscriptLog(folder: $0.folder())) }
        self.logs = Dictionary(uniqueKeysWithValues: logs)
        Task.detached {
            let activity = await withTaskGroup(of: (String, TranscriptLog.Activity).self) { group in
                for (id, log) in logs { group.addTask { (id, await log.activity(at: now)) } }
                return await group.reduce(into: [String: TranscriptLog.Activity]()) { $0[$1.0] = $1.1 }
            }
            let readings = usages.all(registry)
            // Claude's comes from its transcripts, which TranscriptLog has just walked.
            let active = registry.accounts.reduce(into: [String: Date]()) { $0[$1.id] = activity[$1.id]?.lastWrite ?? Sessions.lastActive($1) }
            let identities = unread.reduce(into: [String: Identity]()) { $0[$1.id] = Identity.read($1) }
            await MainActor.run {
                if activity != self.activity { self.activity = activity }
                if active != self.lastActive { self.lastActive = active }
                if !identities.isEmpty { self.identities.merge(identities) { $1 } }
                self.update(readings, at: now)
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

    private func update(_ readings: [String: Usage], at now: Date) {
        if readings != self.readings { self.readings = readings }
        let nowCapped = Set(readings.filter { $0.value.isCapped(at: now) }.keys)
        for id in capped.subtracting(nowCapped) {
            if let account = registry.account(id: id) { ReadyNotice.post(account, readings[id]) }
        }
        capped = nowCapped
    }
}

/// "work is ready": a notification when a capped account's limit resets.
@MainActor
enum ReadyNotice {
    /// Notifications need an app bundle; a bare `swift run` has none.
    private static let center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    static func prepare() {
        center?.delegate = Presenter.shared
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ account: Account, _ usage: Usage?) {
        let content = UNMutableNotificationContent()
        content.title = "\(account.label) is ready"
        content.body = "Its \(account.tool.spec.name) limit has reset" + (usage.map { " (\(UsageFormat.summary($0, tool: account.tool)))" } ?? "") + "."
        content.sound = .default
        center?.add(UNNotificationRequest(identifier: "ready-\(account.id)", content: content, trigger: nil))
    }

    /// Without this, macOS drops banners while the panel is open, because the app is frontmost then.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
        static let shared = Presenter()

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }
    }
}
