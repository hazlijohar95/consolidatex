import Foundation
import Testing
@testable import AccCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func usage(_ fiveHour: Double?, _ sevenDay: Double? = nil, resetsIn: TimeInterval = 3600) -> Usage {
    Usage(
        fiveHour: fiveHour.map { Usage.Window(usedPercentage: $0, resetsAt: t0 + resetsIn) },
        sevenDay: sevenDay.map { Usage.Window(usedPercentage: $0, resetsAt: t0 + 86_400 * 3) },
        recordedAt: t0)
}

@Suite struct UsageRanking {
    @Test func tighterWindowDecides() { #expect(usage(20, 85).load(at: t0) == 85) }
    @Test func passedWindowCountsAsReset() { #expect(usage(99, resetsIn: -1).load(at: t0) == 0) }

    @Test func roomiestFirstUnknownInTheMiddle() {
        let ranked = sample.byHeadroom(["team": usage(95), "personal": usage(10), "cto": usage(60)], at: t0)
        #expect(ranked.map(\.id) == ["personal", "hello", "cto", "team"])
    }

    @Test func excludesTheSource() {
        #expect(sample.byHeadroom(["personal": usage(10)], at: t0, excluding: ["personal"]).first?.id == "team")
    }

    @Test func summaryShowsResetOnlyWhenTight() {
        #expect(UsageFormat.summary(usage(40, 10), at: t0) == "5h 40% · 7d 10%")
        #expect(UsageFormat.summary(usage(85), at: t0) == "5h 85% · resets in 1h")
        #expect(UsageFormat.summary(nil, at: t0) == "no data yet")
    }

    @Test func storeRoundTrip() throws {
        let store = UsageStore(registryStore: tempStore())
        try store.record(usage(42, 7), for: "cto")
        #expect(store.load("cto") == usage(42, 7))
        #expect(store.load("hello") == nil)
    }
}

@Suite struct StatusRendering {
    let input = try! JSONDecoder().decode(StatusInput.self, from: Data("""
        {"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":33.6},
         "rate_limits":{"five_hour":{"used_percentage":91.2,"resets_at":\(t0.timeIntervalSince1970 + 600)}}}
        """.utf8))

    @Test func parsesLiveUsage() {
        #expect(input.usage(at: t0) == Usage(fiveHour: .init(usedPercentage: 91.2, resetsAt: t0 + 600), sevenDay: nil, recordedAt: t0))
    }

    @Test func nudgesTowardRoomWhenNearlyOut() {
        let line = StatusLine.render(account: sample.accounts[2], usage: input.usage(at: t0), input: input,
                                     suggestion: sample.accounts[3], now: t0, color: false)
        #expect(line == "✳ CTO · 5h 91% · Opus 5.5 · ctx 34%  ⇢ acc continue hello")
    }

    @Test func noNudgeWithRoom() {
        let line = StatusLine.render(account: sample.accounts[2], usage: usage(30), input: .empty,
                                     suggestion: sample.accounts[3], now: t0, color: false)
        #expect(line == "✳ CTO · 5h 30%")
    }

    @Test func accountFromConfigDir() {
        #expect(sample.account(forConfigDir: nil)?.id == "team")
        #expect(sample.account(forConfigDir: "")?.id == "team")
        #expect(sample.account(forConfigDir: "/abs/hello/")?.id == "hello")
        #expect(sample.account(forConfigDir: "/elsewhere") == nil)
    }
}

@Suite struct SessionFiles {
    @Test func slugMatchesClaudeCode() {
        // Observed on disk for this path.
        #expect(Sessions.slug(for: "/Users/hazlijohar/.t3/scratch/2026-10-27-hey") == "-Users-hazlijohar--t3-scratch-2026-10-27-hey")
    }

    @Test func newestAcrossAccountsAndCopyWithSidecar() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acc-home-\(UUID().uuidString)").path
        let fm = FileManager.default
        let slug = Sessions.slug(for: "/work/app")
        func write(_ account: Account, _ id: String, age: TimeInterval) throws {
            let dir = AccountPaths(account, home: home).projects + "/" + slug
            try fm.createDirectory(atPath: dir + "/" + id + "/subagents", withIntermediateDirectories: true)
            fm.createFile(atPath: dir + "/" + id + ".jsonl", contents: Data(id.utf8))
            try fm.setAttributes([.modificationDate: Date() - age], ofItemAtPath: dir + "/" + id + ".jsonl")
        }
        try write(sample.accounts[0], "old", age: 600)
        try write(sample.accounts[1], "new", age: 10)

        let sessions = Sessions.forProject("/work/app", in: sample, home: home)
        #expect(sessions.map(\.id) == ["new", "old"])
        #expect(sessions[0].account.id == "personal")

        try Sessions.copy(sessions[0], to: sample.accounts[2], home: home)
        let target = AccountPaths(sample.accounts[2], home: home).projects + "/" + slug
        #expect(fm.contents(atPath: target + "/new.jsonl") == Data("new".utf8))
        #expect(fm.fileExists(atPath: target + "/new/subagents"))
    }
}

@Suite struct SharedConfig {
    @Test func linksMissingKeepsLocalReportsDrift() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acc-home-\(UUID().uuidString)").path
        let fm = FileManager.default
        let primary = sample.accounts[0], other = sample.accounts[2]
        let p = AccountPaths(primary, home: home), o = AccountPaths(other, home: home)
        try fm.createDirectory(atPath: p.configDir + "/skills", withIntermediateDirectories: true)
        fm.createFile(atPath: p.configDir + "/CLAUDE.md", contents: Data("rules".utf8))
        fm.createFile(atPath: p.configDir + "/settings.json", contents: Data("{}".utf8))
        try fm.createDirectory(atPath: o.configDir, withIntermediateDirectories: true)
        fm.createFile(atPath: o.configDir + "/settings.json", contents: Data("{\"own\":1}".utf8))

        #expect(try Shared.link(other, primary: primary, home: home) == ["CLAUDE.md", "skills"])
        let states = Dictionary(uniqueKeysWithValues: Shared.links(for: other, primary: primary, home: home).map { ($0.item, $0.state) })
        #expect(states == ["CLAUDE.md": .linked, "skills": .linked, "settings.json": .local])
        #expect(fm.contents(atPath: o.configDir + "/settings.json") == Data("{\"own\":1}".utf8))
        #expect(Shared.links(for: primary, primary: primary, home: home).isEmpty)

        fm.createFile(atPath: p.stateFile, contents: Data(#"{"mcpServers":{"a":{"url":"x"},"b":{"url":"y"}}}"#.utf8))
        fm.createFile(atPath: o.stateFile, contents: Data(#"{"mcpServers":{"b":{"url":"CHANGED"},"c":{"url":"z"}}}"#.utf8))
        #expect(Shared.mcpDrift(other, primary: primary, home: home) == Shared.MCPDrift(missing: ["a"], extra: ["c"], different: ["b"]))
    }
}
