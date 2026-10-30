import Foundation
import Testing
@testable import AccCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func usage(_ fiveHour: Double?, _ sevenDay: Double? = nil, resetsIn: TimeInterval = 3600) -> Usage {
    Usage(windows: [fiveHour.map { Usage.Window(label: "5h", usedPercentage: $0, resetsAt: t0 + resetsIn) },
                    sevenDay.map { Usage.Window(label: "7d", usedPercentage: $0, resetsAt: t0 + 86_400 * 3) }].compactMap { $0 },
          recordedAt: t0)
}

func write(_ text: String, to path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

@Suite struct UsageRanking {
    @Test func fullestWindowDecides() { #expect(usage(20, 85).load(at: t0) == 85) }
    @Test func passedWindowCountsAsReset() { #expect(usage(99, resetsIn: -1).load(at: t0) == 0) }
    @Test func windowLabels() {
        #expect(Usage.Window.label(minutes: 300) == "5h")
        #expect(Usage.Window.label(minutes: 10080) == "7d")
        #expect(Usage.Window.label(minutes: 43200) == "30d")
    }

    @Test func roomiestWithinOneTool() {
        let u = ["team": usage(95), "personal": usage(10), "cto": usage(60), "side": usage(1)]
        #expect(sample.byHeadroom(.claude, u, at: t0).map(\.id) == ["personal", "cto", "team"])
        #expect(sample.roomiest(.claude, u, excluding: "personal", at: t0)?.id == "cto")
        #expect(sample.roomiest(.codex, u, at: t0)?.id == "side")
    }

    @Test func summary() {
        #expect(UsageFormat.summary(usage(40, 10), at: t0) == "5h 40% · 7d 10%")
        #expect(UsageFormat.summary(usage(85), at: t0) == "5h 85% · resets in 1h")
        #expect(UsageFormat.summary(nil, tool: .opencode, at: t0) == "no usage data")
    }
}

@Suite struct ClaudeStatusLine {
    let input = try! JSONDecoder().decode(StatusInput.self, from: Data("""
        {"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":33.6},
         "rate_limits":{"five_hour":{"used_percentage":91.2,"resets_at":\(t0.timeIntervalSince1970 + 600)}}}
        """.utf8))

    @Test func parsesLiveUsage() {
        #expect(input.usage(at: t0) == Usage(windows: [.init(label: "5h", usedPercentage: 91.2, resetsAt: t0 + 600)], recordedAt: t0))
    }

    @Test func nudgesWhenNearlyOut() {
        let line = StatusLine.render(account: sample.account(id: "cto"), usage: input.usage(at: t0), input: input,
                                     suggestion: sample.account(id: "personal"), now: t0, color: false)
        #expect(line == "✳ CTO · 5h 91% · Opus 5.5 · ctx 34%  ⇢ acc continue personal")
    }

    @Test func slugMatchesClaudeCode() {
        #expect(ClaudeSupport.projectSlug(for: "/Users/hazlijohar/.t3/scratch/2026-10-27-hey") == "-Users-hazlijohar--t3-scratch-2026-10-27-hey")
    }
}

@Suite struct Codex {
    // Shape copied from a real rollout written by codex 0.144.
    let line = #"{"timestamp":"2026-10-30T10:00:00.123Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":24.0,"window_minutes":300,"resets_at":1800003600},"secondary":{"used_percent":61.5,"window_minutes":10080,"resets_at":1800500000},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"plus","rate_limit_reached_type":null}}}"#

    @Test func parsesRateLimits() {
        let u = CodexSupport.parseTokenCount(line)
        #expect(u?.windows.map(\.label) == ["5h", "7d"])
        #expect(u?.windows.map(\.usedPercentage) == [24, 61.5])
        #expect(u?.load(at: t0) == 61.5)
    }

    @Test func ignoresOtherLimitsAndEvents() {
        #expect(CodexSupport.parseTokenCount(line.replacingOccurrences(of: #""limit_id":"codex""#, with: #""limit_id":"codex_other""#)) == nil)
        #expect(CodexSupport.parseTokenCount(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#) == nil)
    }

    @Test func sessionIDFromFileName() {
        #expect(CodexSupport.sessionID(fromFileName: "rollout-2026-10-30T10-00-00-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl") == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        #expect(CodexSupport.sessionID(fromFileName: "notes.jsonl") == nil)
    }

    @Test func identityFromIDToken() {
        let home = tempHome()
        let claims = #"{"email":"me@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
        let payload = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        write(#"{"tokens":{"id_token":"eyJhbGciOiJub25lIn0.\#(payload).sig"}}"#, to: home + "/auth.json")
        let id = CodexSupport.identity(home: home)
        #expect(id.email == "me@example.com")
        #expect(id.plan == "pro")
    }

    @Test func usageAndSessionsFromRollouts() throws {
        let home = tempHome()
        let work = Account(id: "work", tool: .codex, label: "Work", configDir: home + "/a")
        let side = Account(id: "side", tool: .codex, label: "Side", configDir: home + "/b")
        let uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        let file = home + "/a/sessions/2026/10/30/rollout-2026-10-30T10-00-00-\(uuid).jsonl"
        write(#"{"timestamp":"x","type":"session_meta","payload":{"id":"\#(uuid)","cwd":"/work/app"}}"# + "\n" + line + "\n", to: file)
        write(#"{"type":"session_meta","payload":{"id":"other","cwd":"/elsewhere"}}"# + "\n",
              to: home + "/a/sessions/2026/10/29/rollout-2026-10-29T09-00-00-11111111-2222-3333-4444-555555555555.jsonl")

        #expect(CodexSupport.latestUsage(home: home + "/a")?.load(at: t0) == 61.5)
        let registry = Registry(current: [.codex: "work"], accounts: [work, side])
        let sessions = Sessions.forProject("/work/app", in: registry, home: home)
        #expect(sessions.map(\.id) == [uuid])

        try Sessions.copy(sessions[0], to: side, home: home)
        #expect(FileManager.default.fileExists(atPath: home + "/b/sessions/2026/10/30/rollout-2026-10-30T10-00-00-\(uuid).jsonl"))
        #expect(Sessions.resumeArguments(sessions[0]) == ["resume", uuid])
    }
}

@Suite struct Launching {
    @Test func defaultAccountUnsetsVariableOthersSetItAndOpencodeGoesStandalone() {
        let codex = Runner(tool: .codex, executable: "/bin/codex")
        let base = ["CODEX_HOME": "/stale", "X": "1"]
        #expect(codex.environment(for: sample.account(id: "work")!, base: base) == ["X": "1"])
        #expect(codex.environment(for: sample.account(id: "side")!, base: base) == ["CODEX_HOME": "/abs/side", "X": "1"])

        let oc = Runner(tool: .opencode, executable: "/bin/opencode")
        let mine = Account(id: "mine", tool: .opencode, label: "Mine", configDir: "/abs/oc")
        #expect(oc.arguments(for: mine, ["run", "hi"]) == ["--standalone", "run", "hi"])
        #expect(oc.environment(for: mine, base: [:]) == ["XDG_DATA_HOME": "/abs/oc"])
        #expect(oc.arguments(for: Account(id: "d", tool: .opencode, label: "D", configDir: nil), ["run"]) == ["run"])
    }
}

@Suite struct SharedConfig {
    @Test func codexAccountsShareConfigTomlAndAgents() throws {
        let home = tempHome()
        let primary = Account(id: "work", tool: .codex, label: "Work", configDir: nil)
        let other = Account(id: "side", tool: .codex, label: "Side", configDir: home + "/.codex-side")
        write("model = \"gpt\"", to: home + "/.codex/config.toml")
        write("rules", to: home + "/.codex/AGENTS.md")
        write("{}", to: home + "/.codex-side/auth.json")
        write("own", to: home + "/.codex-side/AGENTS.md")

        #expect(try Shared.link(other, primary: primary, home: home) == ["config.toml"])
        let states = Dictionary(uniqueKeysWithValues: Shared.links(for: other, primary: primary, home: home).map { ($0.item, $0.state) })
        #expect(states == ["config.toml": .linked, "AGENTS.md": .local])
        #expect(try String(contentsOfFile: home + "/.codex-side/config.toml", encoding: .utf8) == "model = \"gpt\"")
        #expect(Shared.issues(other, primary: primary, home: home) == ["keeps its own AGENTS.md instead of work's (move it aside, then acc sync)"])
    }

    @Test func claudeMCPDrift() {
        let home = tempHome()
        let primary = Account(id: "team", tool: .claude, label: "T", configDir: nil)
        let other = Account(id: "cto", tool: .claude, label: "C", configDir: home + "/.claude-cto")
        write(#"{"mcpServers":{"a":{"url":"x"},"b":{"url":"y"}}}"#, to: home + "/.claude.json")
        write(#"{"mcpServers":{"b":{"url":"CHANGED"},"c":{"url":"z"}}}"#, to: home + "/.claude-cto/.claude.json")
        #expect(Shared.mcpDrift(other, primary: primary, home: home) == Shared.MCPDrift(missing: ["a"], extra: ["c"], different: ["b"]))
    }
}

@Suite struct SetupPieces {
    @Test func discoveryFindsDefaultsSiblingsAndT3Names() {
        let home = tempHome()
        write("{}", to: home + "/.claude.json")
        write("{}", to: home + "/.claude-acc2/.claude.json")
        write("{}", to: home + "/.claude-junk/notes.txt")
        write("{}", to: home + "/.codex/config.toml")
        write("{}", to: home + "/.codex-client/auth.json")
        write(#"{"providerInstances":{"a":{"driver":"claudeAgent","displayName":"Haz (team)","enabled":true},"b":{"driver":"claudeAgent","displayName":"Haz (Personal)","enabled":true,"config":{"homePath":"~/.claude-acc2"}}}}"#,
              to: home + "/.t3/userdata/settings.json")

        let found = Discovery.find(home: home)
        #expect(found.map(\.label) == ["Haz (team)", "Haz (Personal)", "Codex (default)", "client"])
        #expect(found.map(\.configDir) == [nil, "~/.claude-acc2", nil, "~/.codex-client"])

        let known = Registry(current: [.claude: "t"], accounts: [Account(id: "t", tool: .claude, label: "T", configDir: nil),
                                                                  Account(id: "p", tool: .claude, label: "P", configDir: "~/.claude-acc2")])
        #expect(Discovery.find(home: home, excluding: known).map(\.tool) == [.codex, .codex])
    }

    @Test func shellScripts() {
        #expect(ShellInit.script(for: .zsh).contains(#"codex() { command acc launch codex -- "$@"; }"#))
        #expect(ShellInit.script(for: .fish).contains("function opencode --wraps opencode\n    command acc launch opencode -- $argv\nend"))
    }

    @Test func hookIsAddedOnceAndReplacesLegacyLine() throws {
        let home = tempHome()
        write("export A=1", to: home + "/.zshrc")
        #expect(try ShellInit.installHook(.zsh, home: home) == .installed)
        #expect(try ShellInit.installHook(.zsh, home: home) == .alreadyInstalled)
        #expect(try String(contentsOfFile: home + "/.zshrc", encoding: .utf8)
                == "export A=1\n\n\(ShellInit.marker)\n" + #"eval "$(acc shell-init zsh)""# + "\n")

        write("x\n# Claude Code account switcher\nsource ~/.config/acc/acc.zsh\ny\n", to: home + "/.zshrc")
        #expect(try ShellInit.installHook(.zsh, home: home) == .replacedLegacy)
        #expect(try String(contentsOfFile: home + "/.zshrc", encoding: .utf8)
                == "x\n# Claude Code account switcher\n" + #"eval "$(acc shell-init zsh)""# + "\ny\n")

        #expect(try ShellInit.installHook(.fish, home: home) == .installed)
        #expect(FileManager.default.fileExists(atPath: home + "/.config/fish/conf.d/acc.fish"))
    }

    @Test func statusLineIsInsertedKeepingFormatting() throws {
        let home = tempHome()
        let path = home + "/settings.json"
        write("{\n  \"model\": \"opus\"\n}\n", to: path)
        #expect(try StatusLineSetup.install(settings: path, command: "/bin/acc statusline") == .installed)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == "{\n  \"statusLine\": { \"type\": \"command\", \"command\": \"/bin/acc statusline\" },\n  \"model\": \"opus\"\n}\n")
        #expect(try StatusLineSetup.install(settings: path, command: "/bin/acc statusline") == .alreadyInstalled)

        write(#"{"statusLine":{"type":"command","command":"my-line"}}"#, to: path)
        #expect(try StatusLineSetup.install(settings: path, command: "acc statusline") == .otherStatusLine("my-line"))

        write("{}", to: path)
        #expect(try StatusLineSetup.install(settings: path, command: "acc statusline") == .installed)
        #expect((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) != nil)
    }
}
