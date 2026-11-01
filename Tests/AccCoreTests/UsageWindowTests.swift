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
