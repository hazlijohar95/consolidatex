import Foundation
import Testing
@testable import AccCore

/// What the status line reports for an account in use: the shared 5h and 7d windows only.
private func statusLine(_ fiveHour: Double, at time: Date) -> Usage {
    Usage(windows: [.init(minutes: 300, usedPercentage: fiveHour, resetsAt: t0 + 3600),
                    .init(minutes: 10_080, usedPercentage: 40, resetsAt: t0 + 3 * 86_400)], recordedAt: time)
}

/// What Anthropic's usage API reports: the shared windows plus a per-model weekly one.
private let api = Usage(windows: [.init(minutes: 300, usedPercentage: 10, resetsAt: t0 + 3600),
                                  .init(minutes: 10_080, usedPercentage: 40, resetsAt: t0 + 3 * 86_400),
                                  .init(minutes: 10_080, model: "Fable", usedPercentage: 15, resetsAt: t0 + 3 * 86_400)], recordedAt: t0)

@Suite struct WindowReadTimes {
    @Test func aStatusLineMergeKeepsThePerModelWindowsReadTime() {
        let once = statusLine(20, at: t0 + 60).merged(over: api, at: t0 + 60)
        let twice = statusLine(25, at: t0 + 120).merged(over: once, at: t0 + 120)
        let fable = twice.windows.first { $0.model == "Fable" }
        #expect(fable?.usedPercentage == 15)
        #expect(fable?.readAt == t0)
        #expect(twice.oldestRead == t0)
        #expect(statusLine(25, at: t0 + 120).oldestRead == t0 + 120)
    }

    @Test func aKeptWindowForecastsFromWhenItWasRead() {
        // 60% three days into the week, read at t0: 20% a day fills it at t0 + 2 days. Projected from
        // a day later instead, the same 60% is a slower pace that only fills it in the week's last hours.
        let weekly = Usage.Window(minutes: 10_080, model: "Fable", usedPercentage: 60, resetsAt: t0 + 4 * 86_400, readAt: t0)
        let reading = Usage(windows: [weekly], recordedAt: t0 + 86_400)
        #expect(reading.forecast(at: t0 + 86_400, active: false)?.capsAt == t0 + 2 * 86_400)
    }

    @Test func theStoreKeepsReadTimesAndStillSkipsUnchangedRewrites() throws {
        let store = UsageStore(registryStore: tempStore())
        try store.merge(api, for: "a", at: t0)
        try store.merge(statusLine(20, at: t0 + 10), for: "a", at: t0 + 10)
        #expect(try store.merge(statusLine(20, at: t0 + 30), for: "a", at: t0 + 30).recordedAt == t0 + 10)
        try store.merge(statusLine(20, at: t0 + 80), for: "a", at: t0 + 80)
        let stored = try #require(store.load("a"))
        #expect(stored.recordedAt == t0 + 80)
        #expect(stored.oldestRead == t0)
    }

    @Test func usageFilesWithoutReadTimesStillLoad() throws {
        let store = UsageStore(registryStore: tempStore())
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"recordedAt":1800000000,"windows":[{"minutes":300,"resetsAt":1800003600,"usedPercentage":20},{"minutes":10080,"model":"Fable","resetsAt":1800500000,"usedPercentage":15}]}"#.utf8)
            .write(to: store.directory.appendingPathComponent("a.json"))
        let loaded = try #require(store.load("a"))
        #expect(loaded.windows.map(\.label) == ["5h", "7d Fable"])
        #expect(loaded.oldestRead == t0)
    }
}

@Suite struct AskingLive {
    @Test func anAccountInUseIsAskedOnceItsPerModelWindowAges() throws {
        let store = UsageStore(registryStore: tempStore())
        var schedule = LiveUsage.Schedule()
        try store.merge(api, for: "a", at: t0)
        schedule.record(.reading(api), for: "a", at: t0)
        // The status line writes a changed reading every minute while the account is in use.
        for minute in 1...5 { try store.merge(statusLine(10 + Double(minute), at: t0 + Double(minute) * 60), for: "a", at: t0 + Double(minute) * 60) }
        let readings = ["a": try #require(store.load("a"))]
        #expect(schedule.toAsk(["a"], readings: readings, at: t0 + 240) == [])
        #expect(schedule.toAsk(["a"], readings: readings, at: t0 + 300) == ["a"])
    }

    @Test func aReadingWithEveryWindowFreshIsNotAsked() {
        let schedule = LiveUsage.Schedule()
        let readings = ["codex": statusLine(30, at: t0 + 200)]
        #expect(schedule.toAsk(["codex", "unread"], readings: readings, at: t0 + 300) == ["unread"])
        #expect(schedule.toAsk(["codex", "unread"], readings: readings, at: t0 + 300, force: true) == ["codex", "unread"])
    }

    @Test func forceStillHonoursRetryAfter() {
        var schedule = LiveUsage.Schedule()
        schedule.record(.retryAfter(900), for: "a", at: t0)
        #expect(schedule.toAsk(["a"], readings: [:], at: t0 + 60, force: true) == [])
        #expect(schedule.toAsk(["a"], readings: [:], at: t0 + 900, force: true) == ["a"])
    }
}

@Suite struct HistoryAcrossRelaunch {
    @Test func latestIsTheLastSampleWritten() throws {
        let history = UsageHistory(usageStore: UsageStore(registryStore: tempStore()))
        #expect(history.latest(for: "a") == nil)
        // Long enough that the file is more than the end that gets read.
        let samples = (0..<300).map { UsageHistory.Sample(at: t0 + Double($0) * 900, load: 20, week: 30, apps: .init([.terminal: $0])) }
        for s in samples { try history.append(s, for: "a") }
        #expect(history.latest(for: "a") == samples.last)
    }

    @Test func aHalfWrittenLastLineIsSkipped() throws {
        let history = UsageHistory(usageStore: UsageStore(registryStore: tempStore()))
        let sample = UsageHistory.Sample(at: t0, load: 20, week: 30)
        try history.append(sample, for: "a")
        let file = try FileHandle(forWritingTo: history.directory.appendingPathComponent("a.jsonl"))
        try file.seekToEnd()
        try file.write(contentsOf: Data(#"{"at":18000009"#.utf8))
        try file.close()
        #expect(history.latest(for: "a") == sample)
    }
}

/// The `limits` of real replies from Anthropic's usage endpoint, read at `asked`.
private enum Replies {
    static let asked = Date(iso8601: "2026-11-01T20:30:00Z")!
    /// A 5-hour window under way, a weekly limit all models share, and Fable's own weekly limit.
    static let personal = reply(#"""
        [{"kind":"session","group":"session","percent":14,"resets_at":"2026-11-01T23:20:00.363023+00:00","scope":null},
         {"kind":"weekly_all","group":"weekly","percent":84,"resets_at":"2026-11-03T12:00:00.363043+00:00","scope":null},
         {"kind":"weekly_scoped","group":"weekly","percent":30,"resets_at":"2026-11-03T12:00:00.363247+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}]
        """#)
    /// Out of its 5-hour window.
    static let cto = reply(#"""
        [{"kind":"session","group":"session","percent":100,"resets_at":"2026-11-01T21:40:00.468666+00:00","scope":null},
         {"kind":"weekly_scoped","group":"weekly","percent":100,"resets_at":"2026-11-03T10:00:00.468814+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}]
        """#)
    /// Idle, with Fable's weekly limit used up and no weekly limit shared by all models.
    static let qeel = reply(#"""
        [{"kind":"session","group":"session","percent":0,"resets_at":null,"scope":null},
         {"kind":"weekly_scoped","group":"weekly","percent":100,"resets_at":"2026-11-03T10:00:00.468814+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}]
        """#)

    private static func reply(_ limits: String) -> Usage {
        ClaudeUsageAPI.parse(Data(#"{"limits":\#(limits)}"#.utf8), at: asked)!
    }
}

@Suite struct PerModelLimits {
    let now = Replies.asked
    let registry = Registry(current: [.claude: "cto"], accounts: [
        Account(id: "cto", tool: .claude, label: "CTO", configDir: "~/.claude-acc4"),
        Account(id: "qeel", tool: .claude, label: "Qeel", configDir: "~/.claude-acc3"),
    ])

    @Test func oneModelsWeeklyLimitLeavesTheAccountWorking() {
        #expect(!Replies.qeel.isCapped(at: now))
        #expect(Replies.qeel.load(at: now) == 0)
        #expect(UsageFormat.summary(Replies.qeel, at: now) == "5h 0% · 7d Fable 100%")
    }

    @Test func aCappedAccountMovesToOneCappedOnlyOnAModel() {
        #expect(Replies.cto.isCapped(at: now))
        let readings = ["cto": Replies.cto, "qeel": Replies.qeel]
        #expect(registry.roomiest(.claude, readings, excluding: "cto", at: now)?.id == "qeel")
        #expect(registry.autoPick(.claude, readings, detour: nil, at: now)?.id == "qeel")
    }

    @Test func oneModelUsedUpRanksAboveMostOfTheWeekGone() {
        let three = Registry(current: [.claude: "cto"], accounts: registry.accounts + [
            Account(id: "personal", tool: .claude, label: "Personal", configDir: "~/.claude-acc2"),
        ])
        let readings = ["cto": Replies.cto, "personal": Replies.personal, "qeel": Replies.qeel]
        #expect(three.byHeadroom(.claude, readings, at: now).map(\.id) == ["qeel", "personal", "cto"])
    }

    @Test func theWeeklyLimitAllModelsShareStillCounts() {
        #expect(Replies.personal.load(at: now) == 84)
        #expect(UsageFormat.summary(Replies.personal, at: now) == "5h 14% · 7d 84% · 7d Fable 30% · resets in 1d")
    }

    @Test func historyRecordsOnlyLimitsTheWholeAccountShares() {
        let qeel = UsageHistory.Sample(Replies.qeel, at: now)
        #expect(qeel.load == 0)
        #expect(qeel.week == nil)
        #expect(UsageHistory.Sample(Replies.personal, at: now).week == 84)
    }
}

@Suite struct ExpiredLogins {
    @Test func anExpiredTokenIsNotALoginFailure() async {
        let expired = ClaudeUsageAPI.Login(accessToken: "unused", expiresAt: (t0 - 60).timeIntervalSince1970 * 1000)
        #expect(await ClaudeUsageAPI.fetch(with: expired, at: t0) == .tokenExpired)
    }

    @Test func aTokenAboutToExpireCountsAsExpired() async {
        let expiring = ClaudeUsageAPI.Login(accessToken: "unused", expiresAt: (t0 + 30).timeIntervalSince1970 * 1000)
        #expect(await ClaudeUsageAPI.fetch(with: expiring, at: t0) == .tokenExpired)
    }

    @Test func noLoginIsStillAFailure() async {
        #expect(await ClaudeUsageAPI.fetch(with: nil, at: t0) == .failed("Not logged in"))
    }
}
