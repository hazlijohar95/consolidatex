import Foundation
import Testing
@testable import AccCore

func append(_ text: String, to path: String) throws {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

/// `acc continue` copies a conversation into another account's folder. What came with the copy is
/// the first account's work, so the target counts only what it adds; resuming still reads it all.
@Suite struct ContinuedConversations {
    let project = "/work/app"
    let now = Date()

    func reply(_ id: String, _ tokens: Int, ago: TimeInterval) -> String {
        #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: now - ago))","requestId":"r-\#(id)","entrypoint":"cli","cwd":"\#(project)","message":{"id":"\#(id)","usage":{"output_tokens":\#(tokens)}}}"# + "\n"
    }

    func claude(_ id: String, _ home: String) -> Account {
        Account(id: id, tool: .claude, label: id, configDir: home + "/.claude-" + id)
    }

    func session(on account: Account, _ registry: Registry, _ home: String) throws -> Session {
        try #require(Sessions.forProject(project, in: registry, home: home).first { $0.account == account })
    }

    @Test func claudeCountsOnlyWhatTheTargetAdds() async throws {
        let home = tempHome(), a = claude("a", home), b = claude("b", home)
        let slug = ClaudeSupport.projectSlug(for: project)
        write(reply("a1", 40, ago: 120), to: a.folder(home: home) + "/projects/\(slug)/s1.jsonl")
        write(reply("a2", 5, ago: 100), to: a.folder(home: home) + "/projects/\(slug)/s1/subagents/agent-1.jsonl")
        let registry = Registry(current: [.claude: "a"], accounts: [a, b])
        try Sessions.copy(session(on: a, registry, home), to: b, home: home)

        let log = TranscriptLog(folder: b.folder(home: home))
        #expect(await log.activity(at: now).requests == 0)
        #expect(Sessions.latest(b, home: home) == Sessions.Conversation(id: "s1", folder: project))
        try append(reply("b1", 7, ago: 10), to: b.folder(home: home) + "/projects/\(slug)/s1.jsonl")
        let after = await log.activity(at: now)
        #expect((after.outputTokens, after.requests) == (7, 1))
        #expect(await log.tokens(since: now - 3600, until: now) == [.terminal: 7])
        #expect(await TranscriptLog(folder: a.folder(home: home)).activity(at: now).outputTokens == 45)
    }

    /// A → B, B works, then B → C: what B added came to C with the copy, so C counts none of it.
    @Test func aSecondCopyIsMarkedAtItsOwnLength() async throws {
        let home = tempHome(), a = claude("a", home), b = claude("b", home), c = claude("c", home)
        let file = { (account: Account) in account.folder(home: home) + "/projects/\(ClaudeSupport.projectSlug(for: project))/s1.jsonl" }
        write(reply("a1", 40, ago: 120), to: file(a))
        let registry = Registry(current: [.claude: "a"], accounts: [a, b, c])
        try Sessions.copy(session(on: a, registry, home), to: b, home: home)
        try append(reply("b1", 7, ago: 60), to: file(b))
        try Sessions.copy(session(on: b, registry, home), to: c, home: home)

        #expect(await TranscriptLog(folder: b.folder(home: home)).activity(at: now).outputTokens == 7)
        #expect(await TranscriptLog(folder: c.folder(home: home)).activity(at: now).requests == 0)
    }

    @Test func codexUsageStaysTheTargetsOwn() throws {
        let home = tempHome()
        let a = Account(id: "a", tool: .codex, label: "A", configDir: home + "/.codex-a")
        let b = Account(id: "b", tool: .codex, label: "B", configDir: home + "/.codex-b")
        let uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let rollout = "/sessions/2026/10/30/rollout-2026-10-30T10-00-00-\(uuid).jsonl"
        func tokenCount(_ percent: Int, ago: TimeInterval) -> String {
            #"{"timestamp":"\#(ISO8601DateFormatter().string(from: now - ago))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(percent),"window_minutes":300,"resets_at":\#(Int(now.timeIntervalSince1970) + 3600)}}}}"# + "\n"
        }
        write(#"{"timestamp":"2026-10-30T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(uuid)","cwd":"\#(project)"}}"# + "\n"
              + tokenCount(100, ago: 60), to: a.folder(home: home) + rollout)
        let store = UsageStore(registryStore: tempStore())
        let own = Usage(windows: [.init(minutes: 300, usedPercentage: 10, resetsAt: now + 3600)], recordedAt: now - 3600)
        try store.merge(own, for: "b", at: now - 3600)
        let registry = Registry(current: [.codex: "a"], accounts: [a, b])
        try Sessions.copy(session(on: a, registry, home), to: b, home: home)

        let usages = Usages(store: store)
        #expect(usages.usage(for: b)?.load(at: now) == 10)
        #expect(Sessions.latest(b, home: home) == Sessions.Conversation(id: uuid, folder: project))
        try append(tokenCount(12, ago: 0), to: b.folder(home: home) + rollout)
        #expect(usages.usage(for: b)?.load(at: now) == 12)
        #expect(usages.usage(for: a)?.load(at: now) == 100)
    }
}

/// A reading is as old as its event. One taken as new each time it's read would hide every later
/// reading and never age.
@Suite struct CodexReadingTimes {
    let undated = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":90,"window_minutes":300,"resets_at":1800003600}}}}"#

    func dated(_ timestamp: String, percent: Int) -> String {
        undated.replacingOccurrences(of: #"{"type""#, with: #"{"timestamp":"\#(timestamp)","type""#)
            .replacingOccurrences(of: #""used_percent":90"#, with: #""used_percent":\#(percent)"#)
    }

    @Test func aTokenCountWithoutATimeIsNoReading() {
        #expect(CodexSupport.parseTokenCount(undated) == nil)
        for timestamp in ["2026-10-30T10:00:00Z", "2026-10-30T10:00:00.500Z"] {
            #expect(CodexSupport.parseTokenCount(dated(timestamp, percent: 40))?.recordedAt == Date(timeIntervalSince1970: 1_793_354_400))
        }
    }

    @Test func theNewestDatedTokenCountWins() {
        let file = tempHome() + "/rollout.jsonl"
        write(dated("2026-10-30T10:00:00Z", percent: 40) + "\n" + undated + "\n", to: file)
        let usage = CodexSupport.lastTokenCount(in: URL(fileURLWithPath: file), bytes: 1 << 20)
        #expect(usage?.recordedAt == Date(timeIntervalSince1970: 1_793_354_400))
        #expect(usage?.windows.first?.usedPercentage == 40)
    }
}

@Suite struct CodexAppServerExits {
    /// Writing to a Codex that stopped reading raises SIGPIPE, which would end the app.
    @Test func aCodexThatStopsReadingIsAFailedRead() throws {
        let home = tempHome(), stub = home + "/codex"
        // Answers initialize only after closing its input, so the usage request meets a closed pipe.
        write("""
            #!/bin/sh
            read -r line
            exec 0<&-
            echo '{"id":1,"result":{"userAgent":"codex/1"}}'
            sleep 5
            """, to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        let account = Account(id: "w", tool: .codex, label: "W", configDir: home + "/.codex-w")
        #expect(CodexSupport.liveUsage(Runner(tool: .codex, executable: stub), account, timeout: 5) == .failed("Codex didn't answer the usage request"))
    }
}
