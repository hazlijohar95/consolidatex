import Foundation
import Testing
@testable import AccCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func usage(_ fiveHour: Double?, _ sevenDay: Double? = nil, resetsIn: TimeInterval = 3600) -> Usage {
    Usage(windows: [fiveHour.map { Usage.Window(minutes: 300, usedPercentage: $0, resetsAt: t0 + resetsIn) },
                    sevenDay.map { Usage.Window(minutes: 10_080, usedPercentage: $0, resetsAt: t0 + 86_400 * 3) }].compactMap { $0},
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
        #expect(Usage.Window.label(minutes: 0) == "limit")
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

@Suite struct Forecasting {
    let weekly = Usage.Window(minutes: 10_080, usedPercentage: 60, resetsAt: t0 + 4 * 86_400)
    let session = Usage.Window(minutes: 300, usedPercentage: 90, resetsAt: t0 + 3600)

    @Test func projectsTheAverageRateForward() {
        // Opened 3 days ago at 60%: 20% a day fills the remaining 40% in 2 days.
        #expect(weekly.projectedCap(readAt: t0, now: t0) == t0 + 2 * 86_400)
    }

    @Test func noForecastWhenTheResetComesFirst() {
        #expect(Usage.Window(minutes: 10_080, usedPercentage: 30, resetsAt: t0 + 4 * 86_400).projectedCap(readAt: t0, now: t0) == nil)
    }

    @Test func shortWindowsCountOnlyWhileActive() {
        let u = Usage(windows: [weekly, session], recordedAt: t0)
        #expect(u.forecast(at: t0, active: false)?.window == weekly)
        #expect(u.forecast(at: t0, active: true) == Usage.Forecast(window: session, capsAt: t0 + 1600))
        #expect(usage(100).forecast(at: t0, active: true) == nil)
    }
}

@Suite struct Merging {
    let fable = Usage.Window(minutes: 10_080, model: "Fable", usedPercentage: 52, resetsAt: t0 + 86_400)

    @Test func newerReadingKeepsUnresetWindowsItDoesNotReport() {
        let api = Usage(windows: [.init(minutes: 300, usedPercentage: 10, resetsAt: t0 + 3600), fable], recordedAt: t0)
        let line = Usage(windows: [.init(minutes: 300, usedPercentage: 30, resetsAt: t0 + 3600)], recordedAt: t0 + 60)
        let merged = line.merged(over: api, at: t0 + 60)
        #expect(merged.windows.map(\.label) == ["5h", "7d Fable"])
        #expect(merged.windows.map(\.usedPercentage) == [30, 52])
        #expect(line.merged(over: api, at: t0 + 2 * 86_400).windows.map(\.label) == ["5h"])
    }

    @Test func storeRewritesAnUnchangedReadingOncePerMinute() throws {
        let store = UsageStore(registryStore: tempStore())
        func reading(_ at: Date) -> Usage { Usage(windows: usage(20).windows, recordedAt: at) }
        try store.merge(reading(t0), for: "a", at: t0)
        #expect(try store.merge(reading(t0 + 30), for: "a", at: t0 + 30).recordedAt == t0)
        try store.merge(reading(t0 + 90), for: "a", at: t0 + 90)
        #expect(store.load("a")?.recordedAt == t0 + 90)
        try store.merge(usage(25), for: "a", at: t0 + 100)
        #expect(store.load("a")?.windows.first?.usedPercentage == 25)
    }
}

@Suite struct ClaudeAPI {
    @Test func parsesEveryLimit() {
        let body = #"{"limits":[{"group":"weekly","percent":40,"resets_at":"2027-01-20T08:00:00Z"},{"group":"session","percent":12.5,"resets_at":"2027-01-20T08:00:00.123456Z"},{"group":"weekly","percent":52,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let u = ClaudeUsageAPI.parse(Data(body.utf8), at: t0)
        #expect(u?.windows.map(\.label) == ["5h", "7d", "7d Fable"])
        #expect(u?.windows.map(\.usedPercentage) == [12.5, 40, 52])
        #expect(u?.windows.map(\.resetsAt) == [Date(timeIntervalSince1970: 1_800_432_000), Date(timeIntervalSince1970: 1_800_432_000), nil])
        #expect(ClaudeUsageAPI.parse(Data("{}".utf8), at: t0) == nil)
    }

    @Test func keychainItemFollowsClaudeCodesNaming() {
        let work = Account(id: "w", tool: .claude, label: "W", configDir: "~/.claude-work")
        #expect(ClaudeUsageAPI.keychainService(for: work, home: "/Users/me") == "Claude Code-credentials-1e91dd84")
        #expect(ClaudeUsageAPI.keychainService(for: sample.account(id: "team")!, home: "/Users/me") == "Claude Code-credentials")
    }

    @Test func scheduleSpacesReadsAndHonoursRetryAfter() {
        var schedule = LiveUsage.Schedule()
        #expect(schedule.due(["a", "b"], at: t0) == ["a", "b"])
        schedule.record(.reading(usage(1)), for: "a", at: t0)
        schedule.record(.retryAfter(900), for: "b", at: t0)
        #expect(schedule.due(["a", "b"], at: t0 + 60) == [])
        #expect(schedule.due(["a", "b"], at: t0 + 60, force: true) == ["a"])
        #expect(schedule.due(["a", "b"], at: t0 + 300) == ["a"])
        #expect(schedule.due(["a", "b"], at: t0 + 900) == ["a", "b"])
    }

    @Test func aLaterReadingAnswersAFailedLiveRead() {
        let failure = LiveUsage.Failure("Login expired; one message on this account refreshes it", at: t0)
        #expect(failure.isAnswered(by: Usage(windows: [], recordedAt: t0 + 5)))
        #expect(!failure.isAnswered(by: Usage(windows: [], recordedAt: t0)))
        #expect(!failure.isAnswered(by: Usage(windows: [], recordedAt: t0 - 60)))
        #expect(!failure.isAnswered(by: nil))
    }
}

@Suite struct ClaudeStatusLine {
    let input = try! JSONDecoder().decode(StatusInput.self, from: Data("""
        {"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":33.6},
         "rate_limits":{"five_hour":{"used_percentage":91.2,"resets_at":\(t0.timeIntervalSince1970 + 600)}}}
        """.utf8))

    @Test func parsesLiveUsage() {
        #expect(input.usage(at: t0) == Usage(windows: [.init(minutes: 300, usedPercentage: 91.2, resetsAt: t0 + 600)], recordedAt: t0))
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

    @Test func theNewestTokenCountInATailWins() throws {
        let file = tempHome() + "/rollout.jsonl", url = URL(fileURLWithPath: file)
        let older = line.replacingOccurrences(of: #""used_percent":24.0"#, with: #""used_percent":10.0"#)
        write([older, line, #"{"type":"event_msg","payload":{"type":"agent_message"}}"#].joined(separator: "\n") + "\n", to: file)
        #expect(CodexSupport.lastTokenCount(in: url, bytes: 1 << 20)?.windows.first?.usedPercentage == 24)
        // A tail that starts inside the newest event can't read it, so it reads nothing rather than half a line.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int)
        #expect(CodexSupport.lastTokenCount(in: url, bytes: size - older.utf8.count - 10) == nil)
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
        #expect(CodexSupport.identity(home: home) == Identity(email: "me@example.com", plan: "Pro"))
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
        // A reading stored after the rollouts were last written leaves nothing newer in them.
        #expect(CodexSupport.latestUsage(home: home + "/a", after: Date() + 60) == nil)
        #expect(CodexSupport.latestUsage(home: home + "/a", after: Date() - 60)?.load(at: t0) == 61.5)
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
        write(#"{"oauthAccount":{"emailAddress":"me@cynco.io","organizationType":"claude_max"}}"#, to: home + "/.claude-acc3/.claude.json")
        write(#"{"oauthAccount":{"emailAddress":"me@cynco.io","organizationType":"claude_team"}}"#, to: home + "/.claude-acc4/.claude.json")
        write(#"{"oauthAccount":{"emailAddress":"me@cynco.io","organizationType":"claude_team"}}"#, to: home + "/.claude-acc5/.claude.json")
        write(#"{"providerInstances":{"a":{"driver":"claudeAgent","displayName":"Haz (team)","enabled":true},"b":{"driver":"claudeAgent","displayName":"Haz (Personal)","enabled":true,"config":{"homePath":"~/.claude-acc2"}}}}"#,
              to: home + "/.t3/userdata/settings.json")

        let found = Discovery.find(home: home)
        // One email three times: its name, then with the plan, then the folder.
        #expect(found.map(\.label) == ["Haz (team)", "Haz (Personal)", "me", "me · Team", "acc5", "Codex (default)", "client"])
        #expect(found.map(\.configDir) == [nil, "~/.claude-acc2", "~/.claude-acc3", "~/.claude-acc4", "~/.claude-acc5", nil, "~/.codex-client"])

        let known = Registry(current: [.claude: "t"], accounts: [Account(id: "t", tool: .claude, label: "T", configDir: nil),
                                                                  Account(id: "p", tool: .claude, label: "P", configDir: "~/.claude-acc2")])
        #expect(Discovery.find(home: home, excluding: known).map(\.tool) == [.claude, .claude, .claude, .codex, .codex])
    }

    @Test func shellScripts() {
        #expect(ShellInit.script(for: .zsh).contains(#"function codex { command acc launch codex -- "$@"; }"#))
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
        write("claude() { … }", to: home + "/.config/acc/acc.zsh")
        #expect(try ShellInit.installHook(.zsh, home: home) == .replacedLegacy)
        #expect(!FileManager.default.fileExists(atPath: home + "/.config/acc/acc.zsh"))
        #expect(try String(contentsOfFile: home + "/.zshrc", encoding: .utf8)
                == "x\n# Claude Code account switcher\n" + #"eval "$(acc shell-init zsh)""# + "\ny\n")

        #expect(try ShellInit.installHook(.fish, home: home) == .installed)
        #expect(FileManager.default.fileExists(atPath: home + "/.config/fish/conf.d/acc.fish"))
    }

    @Test func bashHookGoesWhereLoginShellsLook() throws {
        let home = tempHome()
        write("x", to: home + "/.bashrc")
        write("export B=1", to: home + "/.profile")
        #expect(try ShellInit.installHook(.bash, home: home) == .installed)
        #expect(try String(contentsOfFile: home + "/.profile", encoding: .utf8).contains("acc shell-init bash"))
        #expect(!FileManager.default.fileExists(atPath: home + "/.bash_profile"))
        #expect(try String(contentsOfFile: home + "/.bashrc", encoding: .utf8) == "x")

        let fresh = tempHome()
        #expect(try ShellInit.installHook(.bash, home: fresh) == .installed)
        #expect(FileManager.default.fileExists(atPath: fresh + "/.bash_profile"))
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

@Suite struct AppInstalling {
    func makeApp(_ path: String, version: String) {
        write("bin", to: path + "/Contents/MacOS/acc")
        write(#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>\#(version)</string></dict></plist>"#,
              to: path + "/Contents/Info.plist")
    }

    @Test func findsTheBundleThroughHomebrewsSymlink() throws {
        let home = tempHome()
        makeApp(home + "/Cellar/consolidatex/2.1.0/Consolidatex.app", version: "2.1.0")
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/bin/acc",
                                                   withDestinationPath: home + "/Cellar/consolidatex/2.1.0/Consolidatex.app/Contents/MacOS/acc")
        #expect(AppInstall.bundle(containing: home + "/bin/acc") == home + "/Cellar/consolidatex/2.1.0/Consolidatex.app")
        #expect(AppInstall.bundle(containing: "/usr/local/bin/acc") == nil)
    }

    @Test func missingThenCurrentThenOutdated() throws {
        let home = tempHome()
        let keg = home + "/Cellar/consolidatex/2.1.0/Consolidatex.app"
        makeApp(keg, version: "2.1.0")
        let acc = keg + "/Contents/MacOS/acc"
        #expect(AppInstall.status(executable: acc, home: home) == .missing(bundle: keg))

        let installed = try AppInstall.install(keg, home: home)
        #expect(installed == home + "/Applications/Consolidatex.app")
        #expect(AppInstall.status(executable: acc, home: home) == .current(installed))

        makeApp(installed, version: "2.0.0")
        #expect(AppInstall.status(executable: acc, home: home) == .outdated(installed: installed, version: "2.0.0", bundle: keg))
        try AppInstall.install(keg, to: installed, home: home)
        #expect(AppInstall.version(of: installed) == "2.1.0")
        #expect(!FileManager.default.fileExists(atPath: installed + ".installing"))
    }

    @Test func runningFromTheInstalledAppIsInPlace() {
        let home = tempHome()
        let app = home + "/Applications/Consolidatex.app"
        makeApp(app, version: "2.1.0")
        #expect(AppInstall.status(executable: app + "/Contents/MacOS/acc", home: home) == .inPlace(app))
        #expect(AppInstall.status(executable: home + "/.build/release/acc", home: home) == .notBundled)
    }
}

@Suite struct Activity {
    @Test func claudesLastWriteCountsSubagentTranscripts() async throws {
        let home = tempHome(), projects = home + "/projects/p"
        for (name, at) in [("old.jsonl", t0), ("new.jsonl", t0 + 100), ("new/subagents/agent.jsonl", t0 + 500)] {
            write("x", to: projects + "/" + name)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: projects + "/" + name)
        }
        #expect(await TranscriptLog(folder: home).activity(at: t0 + 600).lastWrite == t0 + 500)
        #expect(Sessions.lastActive(Account(id: "o", tool: .opencode, label: "O", configDir: "~/.opencode-o"), home: home) == nil)
    }
}

@Suite struct Identities {
    @Test func claudeLoginAndPlanFromItsStateFile() {
        let home = tempHome()
        write(#"{"oauthAccount":{"emailAddress":"me@cynco.io","organizationType":"claude_team"}}"#, to: home + "/.claude-w/.claude.json")
        write(#"{"oauthAccount":{"emailAddress":"d@cynco.io","organizationType":"claude_max"}}"#, to: home + "/.claude.json")
        #expect(Identity.read(Account(id: "w", tool: .claude, label: "W", configDir: "~/.claude-w"), home: home) == Identity(email: "me@cynco.io", plan: "Team"))
        #expect(Identity.read(Account(id: "d", tool: .claude, label: "D", configDir: nil), home: home)?.plan == "Max")
        #expect(Identity.read(Account(id: "x", tool: .claude, label: "X", configDir: "~/.claude-x"), home: home) == nil)
    }

    @Test func claudeLoginIsFoundAmongTheRestOfTheStateFile() {
        let home = tempHome()
        // The key inside a string is escaped, and the braces inside the login's own strings don't count.
        write(#"{"tips": {"x": "a \"oauthAccount\": {} here"}, "oauthAccount" : {"emailAddress": "me@cynco.io", "organizationType": "claude_max", "note": "}{\"}"}, "after": {}}"#,
              to: home + "/.claude.json")
        #expect(Identity.read(Account(id: "d", tool: .claude, label: "D", configDir: nil), home: home) == Identity(email: "me@cynco.io", plan: "Max"))
        write(#"{"oauthAccount": null}"#, to: home + "/.claude.json")
        #expect(Identity.read(Account(id: "d", tool: .claude, label: "D", configDir: nil), home: home) == nil)
        // Only the top-level key counts: not a prompt that says it, nor an object of the same name further in.
        write(#"{"projects": {"/p": {"history": [{"display": "oauthAccount"}], "cache": {"oauthAccount": {"emailAddress": "old@cynco.io"}}}}, "oauthAccount": {"emailAddress": "me@cynco.io"}}"#,
              to: home + "/.claude.json")
        #expect(Identity.read(Account(id: "d", tool: .claude, label: "D", configDir: nil), home: home)?.email == "me@cynco.io")
    }
}

@Suite struct Transcripts {
    func line(_ id: String, _ tokens: Int, at: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: at))","requestId":"r-\#(id)","message":{"id":"\#(id)","usage":{"output_tokens":\#(tokens)}}}"#
    }

    @Test func countsEachResponseOnceAndOnlyAppendedLinesAfterwards() async throws {
        let home = tempHome(), file = home + "/projects/p/s.jsonl"
        let now = Date()
        // Streaming rewrites a response's count; the old response falls outside the 5 hours.
        write([line("a", 10, at: now - 60), line("a", 40, at: now - 50), line("old", 999, at: now - 6 * 3600),
               #"{"type":"user","message":{"content":"hi"}}"#].joined(separator: "\n") + "\n", to: file)
        let log = TranscriptLog(folder: home)
        let first = await log.activity(at: now)
        #expect((first.outputTokens, first.requests) == (40, 1))

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("b", 5, at: now - 10) + "\n" + line("c", 7, at: now)).utf8))  // c is still being written
        try handle.close()
        let second = await log.activity(at: now)
        #expect((second.outputTokens, second.requests) == (45, 2))
    }

    @Test func readsBlankLinesAndLinesLongerThanTheBuffer() async {
        let home = tempHome(), now = Date()
        let long = line("long", 7, at: now - 30).replacingOccurrences(of: #""message":{"#, with: #""message":{"content":"\#(String(repeating: "x", count: 3 << 20))","#)
        write(["", line("a", 10, at: now - 60), "", long, line("b", 5, at: now - 20)].joined(separator: "\n") + "\n", to: home + "/projects/p/s.jsonl")
        #expect(await TranscriptLog(folder: home).activity(at: now).outputTokens == 22)
    }

    @Test func findsNewTranscriptsWithinAMinuteAndWhenAskedForEveryReply() async {
        let home = tempHome(), now = Date()
        write(line("a", 10, at: now - 60) + "\n", to: home + "/projects/p/s.jsonl")
        let log = TranscriptLog(folder: home)
        #expect(await log.activity(at: now).outputTokens == 10)
        write(line("b", 5, at: now - 30) + "\n", to: home + "/projects/q/s/subagents/agent.jsonl")
        #expect(await log.activity(at: now, complete: true).outputTokens == 15)
        write(line("c", 1, at: now - 20) + "\n", to: home + "/projects/r/later.jsonl")
        #expect(await log.activity(at: now + 60).outputTokens == 16)
    }
}

@Suite struct CodexLive {
    let reply = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":12,"resetsAt":1800500000}}}}"#

    @Test func readsTheSubscriptionsWindows() {
        let expected = Usage(windows: [.init(minutes: 300, usedPercentage: 40, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                                       .init(minutes: 10_080, usedPercentage: 12, resetsAt: Date(timeIntervalSince1970: 1_800_500_000))],
                             recordedAt: t0)
        #expect(CodexSupport.outcome(ofRateLimitsReply: Data(reply.utf8), at: t0) == .reading(expected))
    }

    @Test func readsARealReply() {
        // Copied from codex-cli 0.166.0 on a Free plan.
        let real = #"{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":0,"windowDurationMins":43200,"resetsAt":1795955441},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"individualLimit":null,"spendControlReached":false,"planType":"free","rateLimitReachedType":null}}}"#
        let expected = Usage(windows: [.init(minutes: 43_200, usedPercentage: 0, resetsAt: Date(timeIntervalSince1970: 1_795_955_441))], recordedAt: t0)
        #expect(CodexSupport.outcome(ofRateLimitsReply: Data(real.utf8), at: t0) == .reading(expected))
    }

    @Test func freePlansFirstWindowIsMonthly() {
        let free = #"{"id":2,"result":{"rateLimits":{"planType":"free","primary":{"usedPercent":5,"resetsAt":1800500000}}}}"#
        guard case .reading(let u) = CodexSupport.outcome(ofRateLimitsReply: Data(free.utf8), at: t0) else { Issue.record("no reading"); return }
        #expect(u.windows.map(\.label) == ["30d"])
    }

    @Test func errorsAndOtherLimitsAreFailures() {
        #expect(CodexSupport.outcome(ofRateLimitsReply: Data(#"{"id":2,"error":{"message":"not logged in"}}"#.utf8), at: t0) == .failed("not logged in"))
        let other = reply.replacingOccurrences(of: #""limitId":"codex""#, with: #""limitId":"codex_other""#)
        #expect(CodexSupport.outcome(ofRateLimitsReply: Data(other.utf8), at: t0) == .failed("Codex reported no usage for this account"))
    }

    /// A stand-in app server that answers initialize, then the usage request, only after being asked.
    @Test func talksToTheAppServerOverStdio() throws {
        let home = tempHome(), stub = home + "/codex"
        write("""
            #!/bin/sh
            [ "$1" = app-server ] || exit 2
            while IFS= read -r line; do
              case "$line" in
                *'"initialize"'*) echo '{"method":"notice"}'; echo '{"id":1,"result":{"userAgent":"codex/1"}}';;
                *'"account/rateLimits/read"'*) [ "$CODEX_HOME" = "\(home)/.codex-w" ] && echo '\(reply)';;
              esac
            done
            """, to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        let account = Account(id: "w", tool: .codex, label: "W", configDir: home + "/.codex-w")
        guard case .reading(let u) = CodexSupport.liveUsage(Runner(tool: .codex, executable: stub), account, timeout: 5) else {
            Issue.record("no reading"); return
        }
        #expect(u.windows.map(\.usedPercentage) == [40, 12])

        write("#!/bin/sh\ncat >/dev/null\n", to: stub)
        #expect(CodexSupport.liveUsage(Runner(tool: .codex, executable: stub), account, timeout: 1) == .failed("Codex didn't start its app server"))
    }

    @Test func newestCodexReadingWins() throws {
        let home = tempHome(), store = UsageStore(registryStore: tempStore())
        let account = Account(id: "w", tool: .codex, label: "W", configDir: home + "/.codex-w")
        try store.merge(usage(70), for: "w", at: t0)
        #expect(Usages(store: store).usage(for: account)?.load(at: t0) == 70)
    }
}

@Suite struct ReviewFixes {
    @Test func aStaleReadingNeverForecastsAPastCap() {
        // Read 2 days ago, 2 days into the week, at 50%: the projected cap is today, not ahead.
        let w = Usage.Window(minutes: 10_080, usedPercentage: 50, resetsAt: t0 + 3 * 86_400)
        #expect(w.projectedCap(readAt: t0 - 2 * 86_400, now: t0 + 3600) == nil)
    }

    @Test func usageFilesFromBeforeMinutesStillLoad() throws {
        let store = UsageStore(registryStore: tempStore())
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"recordedAt":1800000000,"windows":[{"label":"5h","usedPercentage":20,"resetsAt":1800003600},{"label":"7d","usedPercentage":40,"resetsAt":1800500000}]}"#.utf8)
            .write(to: store.directory.appendingPathComponent("a.json"))
        #expect(store.load("a")?.windows.map(\.minutes) == [300, 10_080])
    }

    @Test func codexWindowsWithoutAResetAreLeftOut() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300},"secondary":{"used_percent":10,"window_minutes":10080,"resets_at":1800500000}}}}"#
        #expect(CodexSupport.parseTokenCount(line)?.windows.map(\.label) == ["7d"])
    }

    @Test func aBashHookInBashrcStillCounts() throws {
        let home = tempHome()
        write(#"eval "$(acc shell-init bash)""# + "\n", to: home + "/.bashrc")
        #expect(ShellInit.isInstalled(.bash, home: home))
        #expect(try ShellInit.installHook(.bash, home: home) == .alreadyInstalled)
        #expect(!FileManager.default.fileExists(atPath: home + "/.bash_profile"))
    }

    @Test func twoAccountsCannotShareAFolder() {
        var r = sample
        r.accounts.append(Account(id: "again", tool: .codex, label: "Again", configDir: "/abs/side"))
        #expect(throws: AccError.invalidRegistry(["more than one Codex account uses /abs/side"])) { try r.validate() }
    }
}

@Suite struct AutoSwitching {
    @Test func movesOffACappedPickToTheMostRoom() {
        #expect(sample.autoPick(.claude, ["cto": usage(100), "personal": usage(10), "team": usage(60)], detour: nil, at: t0)?.id == "personal")
        #expect(sample.autoPick(.claude, ["cto": usage(100), "personal": usage(95), "team": usage(99)], detour: nil, at: t0) == nil)
    }

    @Test func staysWhileThePickHasRoom() {
        #expect(sample.autoPick(.claude, ["cto": usage(80), "personal": usage(1)], detour: nil, at: t0) == nil)
    }

    @Test func returnsAlongTheDetourOnlyWhileItStillApplies() throws {
        var r = sample
        try r.use("personal")
        let detour = Detour(from: "cto", to: "personal")
        #expect(r.autoPick(.claude, ["cto": usage(20), "personal": usage(10)], detour: detour, at: t0)?.id == "cto")
        #expect(r.autoPick(.claude, ["cto": usage(100), "personal": usage(10)], detour: detour, at: t0) == nil)
        // Reset on 5h but at 98% of the week: going back now would only bounce.
        #expect(r.autoPick(.claude, ["cto": usage(0, 98), "personal": usage(10)], detour: detour, at: t0) == nil)
        // Someone picked another account by hand since: the app leaves it alone.
        try r.use("team")
        #expect(r.autoPick(.claude, ["cto": usage(20), "team": usage(10)], detour: detour, at: t0) == nil)
    }

    @Test func aDetourRemembersThePersonsPickAcrossMoves() {
        let first = Detour.after(moving: "cto", to: "personal", existing: nil)
        #expect(first == Detour(from: "cto", to: "personal"))
        #expect(Detour.after(moving: "personal", to: "team", existing: first) == Detour(from: "cto", to: "team"))
        #expect(Detour.after(moving: "personal", to: "cto", existing: first) == nil)
    }
}

@Suite struct LatestConversation {
    @Test func claudeTakesTheNewestTranscriptAndItsFolder() throws {
        let home = tempHome(), projects = home + "/.claude-c/projects"
        write(#"{"type":"user","cwd":"/old"}"# + "\n", to: projects + "/-old/aaa.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date() - 3600], ofItemAtPath: projects + "/-old/aaa.jsonl")
        // The session started in /work/app, then cd'd into src: it is still filed, and found, under /work/app.
        write(#"{"type":"user","cwd":"/work/app"}"# + "\n" + #"{"type":"user","cwd":"/work/app/src"}"# + "\n", to: projects + "/-work-app/bbb.jsonl")
        let account = Account(id: "c", tool: .claude, label: "C", configDir: "~/.claude-c")
        #expect(Sessions.latest(account, home: home) == Sessions.Conversation(id: "bbb", folder: "/work/app"))
    }

    @Test func codexTakesTheNewestRollout() {
        let home = tempHome(), id = "0199a1b2-aaaa-7e5f-8a9b-0c1d2e3f4a5b"
        write(#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/work/api"}}"# + "\n",
              to: home + "/.codex-w/sessions/2026/10/30/rollout-2026-10-30T11-00-00-\(id).jsonl")
        let account = Account(id: "w", tool: .codex, label: "W", configDir: "~/.codex-w")
        #expect(Sessions.latest(account, home: home) == Sessions.Conversation(id: id, folder: "/work/api"))
    }
}

@Suite struct History {
    @Test func appendsReadsAndPrunes() throws {
        let history = UsageHistory(usageStore: UsageStore(registryStore: tempStore()))
        let old = UsageHistory.Sample(at: t0 - 40 * 86_400, load: 50, week: 20)
        try history.append(old, for: "a")
        try history.append(UsageHistory.Sample(usage(30, 70), at: t0), for: "a")
        #expect(history.samples(for: "a", since: t0 - 100 * 86_400).map(\.load) == [50, 70])
        #expect(history.samples(for: "a", since: t0 - 1).first?.week == 70)
        try history.prune("a", at: t0)
        #expect(history.samples(for: "a", since: .distantPast).count == 1)
    }

    @Test func weekReportCountsCappedHoursAndCoverage() {
        // A sample every 15 minutes: an hour at the limit inside two hours of history.
        let loads: [Double] = [40, 100, 100, 100, 100, 60, 30, 20, 10]
        let samples = loads.enumerated().map { i, load in UsageHistory.Sample(at: t0 - Double(loads.count - i) * 900, load: load, week: 30) }
        let r = WeekReport(account: sample.account(id: "cto")!, samples: samples, current: usage(5, 45), at: t0)
        #expect(r.cappedHours == 1)
        #expect(r.coveredHours == 2)
        #expect(r.weekUsed == 45)
        #expect(r.note == "capped 1h this week")
    }

    @Test func idleNoteNeedsThreeDaysOfHistory() {
        let days = (0..<(4 * 96)).map { UsageHistory.Sample(at: t0 - Double($0) * 900, load: 2, week: 3) }
        let account = sample.account(id: "side")!
        #expect(WeekReport(account: account, samples: days, current: nil, at: t0).note == "mostly idle: 3% of its week used")
        #expect(WeekReport(account: account, samples: Array(days.prefix(8)), current: nil, at: t0).note == nil)
    }
}

@Suite struct LatestCodexByWriteTime {
    @Test func aLongSessionStartedEarlierStillWins() throws {
        let home = tempHome(), day = home + "/.codex-w/sessions/2026/10/30"
        let early = "0199a1b2-0000-7e5f-8a9b-0c1d2e3f4a5b", late = "0199a1b2-1111-7e5f-8a9b-0c1d2e3f4a5b"
        write(#"{"type":"session_meta","payload":{"id":"\#(early)","cwd":"/long"}}"# + "\n", to: day + "/rollout-2026-10-30T08-00-00-\(early).jsonl")
        write(#"{"type":"session_meta","payload":{"id":"\#(late)","cwd":"/short"}}"# + "\n", to: day + "/rollout-2026-10-30T09-00-00-\(late).jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date() - 7200], ofItemAtPath: day + "/rollout-2026-10-30T09-00-00-\(late).jsonl")
        let account = Account(id: "w", tool: .codex, label: "W", configDir: "~/.codex-w")
        #expect(Sessions.latest(account, home: home)?.folder == "/long")
    }

    @Test func reportIsACommandNotAnID() {
        #expect(Registry.reservedIDs.contains("report"))
    }
}

@Suite struct Running {
    /// argc, path, padding, arguments, then the environment, as the kernel lays it out.
    func procArgs(_ arguments: [String], _ environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes += Array("/usr/local/bin/claude".utf8) + [0, 0, 0]
        for s in arguments + environment { bytes += Array(s.utf8) + [0] }
        return bytes + [0]
    }

    @Test func readsOnlyTheVariablesAskedFor() {
        let bytes = procArgs(["claude", "--resume", "x"], ["HOME=/h", "CLAUDE_CONFIG_DIR=/h/.claude-w", "CLAUDE_CODE_OAUTH_TOKEN=secret"])
        let facts = bytes.withUnsafeBytes { RunningSessions.facts(fromProcArgs: $0, variables: ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_ACCOUNT_UUID"]) }
        #expect(facts == RunningSessions.Facts(variables: ["CLAUDE_CONFIG_DIR": "/h/.claude-w"], flagged: false))
    }

    @Test func anEmptyArgumentIsNotMistakenForTheEnvironment() {
        let bytes = procArgs(["claude", "--setting-sources", "", "-p", ""], ["CLAUDE_CONFIG_DIR=/h/.claude-w", "HOME=/h"])
        let facts = bytes.withUnsafeBytes { RunningSessions.facts(fromProcArgs: $0, variables: ["CLAUDE_CONFIG_DIR"]) }
        #expect(facts.variables == ["CLAUDE_CONFIG_DIR": "/h/.claude-w"])
    }

    @Test func aLoginWithoutItsOrganizationFindsTheOnlyAccountWithThatUser() {
        let index = RunningSessions.loginIndex([
            "team": .init(account: "u1", organization: "org-team"), "personal": .init(account: "u1", organization: "org-me"),
            "solo": .init(account: "u2", organization: "org-x"),
        ])
        #expect(index[.init(account: "u1", organization: "org-team")] == "team")
        #expect(index[.init(account: "u2", organization: nil)] == "solo")
        // Two accounts share u1, so without the organization there is no telling which.
        #expect(index[.init(account: "u1", organization: nil)] == nil)
    }

    @Test func spotsTheChromeBridge() {
        let bytes = procArgs(["claude", "--chrome-native-host"], [])
        #expect(bytes.withUnsafeBytes { RunningSessions.facts(fromProcArgs: $0, variables: [], flags: ToolSpec.claude.ignoredArguments) }.flagged)
    }

    @Test func namesKnownAppsByBundleID() {
        #expect(RunningSessions.knownApps.first { "com.superlogical.rex.server".hasPrefix($0.idPrefix) }?.name == "Rex")
    }

    /// A real process named claude, on an account folder, found in the real process table.
    @Test func findsARunningSessionAndItsAccount() throws {
        let home = tempHome()
        let fake = home + "/bin/claude"
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: fake)
        let session = Process(), bridge = Process(), desktop = Process()
        let runs: [(Process, [String], [String: String])] = [
            // An environment larger than the scan's first buffer, which has to grow to read it.
            (session, ["30"], ["PADDING": String(repeating: "x", count: 60_000), "CLAUDE_CONFIG_DIR": home + "/.claude-w"]),
            (bridge, ["30", "--chrome-native-host"], ["CLAUDE_CONFIG_DIR": home + "/.claude-w"]),
            // Started the way Claude desktop starts sessions: a login, no folder.
            (desktop, ["30"], ["CLAUDE_CODE_ACCOUNT_UUID": "user-1", "CLAUDE_CODE_ORGANIZATION_UUID": "org-team"]),
        ]
        for (process, arguments, environment) in runs {
            process.executableURL = URL(fileURLWithPath: fake)
            process.arguments = arguments
            process.environment = environment
            try process.run()
        }
        defer { runs.forEach { $0.0.terminate() } }
        let registry = Registry(current: [.claude: "w"], accounts: [
            Account(id: "w", tool: .claude, label: "W", configDir: "~/.claude-w"),
            Account(id: "team", tool: .claude, label: "Team", configDir: "~/.claude-team"),
        ])
        // One person in two organizations: only the organization tells the accounts apart.
        let logins = ["w": Identity.Login(account: "user-1", organization: "org-personal"), "team": Identity.Login(account: "user-1", organization: "org-team")]
        let ours = Set(runs.map { $0.0.processIdentifier })
        let found = RunningSessions.scan(registry, logins: { logins }, home: home)
            .filter { ours.contains($0.pid) }
        #expect(found.map(\.pid) == [session.processIdentifier, desktop.processIdentifier].sorted())
        #expect(Dictionary(uniqueKeysWithValues: found.map { ($0.pid, $0.accountID) }) == [session.processIdentifier: "w", desktop.processIdentifier: "team"])
    }
}

@Suite struct Origins {
    @Test func whereSessionsRan() {
        #expect(Origin.of(entrypoint: "claude-desktop", cwd: "/x") == .claudeDesktop)
        #expect(Origin.of(entrypoint: "cli", cwd: "/Users/me/.t3/worktrees/a") == .terminal)
        #expect(Origin.of(entrypoint: "sdk-ts", cwd: "/Users/me/.t3/worktrees/a") == .t3Code)
        #expect(Origin.of(entrypoint: "sdk-cli", cwd: "/tmp/t3code-claude-title-x") == .t3Code)
        #expect(Origin.of(entrypoint: "sdk-ts", cwd: "/work") == .otherApp)
    }

    @Test func tokensAreSplitByOriginOneOriginPerTranscript() async {
        let home = tempHome(), now = Date()
        func line(_ id: String, _ tokens: Int, _ entry: String, _ cwd: String, ago: TimeInterval = 60) -> String {
            #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: now - ago))","requestId":"r\#(id)","entrypoint":"\#(entry)","cwd":"\#(cwd)","message":{"id":"\#(id)","usage":{"output_tokens":\#(tokens)}}}"#
        }
        write(line("a", 30, "cli", "/w") + "\n", to: home + "/projects/p/terminal.jsonl")
        write(line("b", 60, "sdk-ts", "/u/.t3/worktrees/x", ago: 3600) + "\n" + line("b2", 5, "sdk-ts", "/u/.t3/worktrees/x") + "\n", to: home + "/projects/q/t3.jsonl")
        write(line("c", 10, "claude-desktop", "/w") + "\n", to: home + "/projects/r/desktop.jsonl")
        let log = TranscriptLog(folder: home)
        let activity = await log.activity(at: now)
        #expect(activity.byOrigin == [.terminal: 30, .t3Code: 65, .claudeDesktop: 10])
        #expect(activity.outputTokens == 105)
        // Since 30 minutes ago: the hour-old T3 reply is left out.
        #expect(await log.tokens(since: now - 1800, until: now) == [.terminal: 30, .t3Code: 5, .claudeDesktop: 10])
        // Up to 2 minutes ago: the replies from a minute ago are the next sample's.
        #expect(await log.tokens(since: now - 1800, until: now - 120) == [:])
    }

    @Test func aReplyCopiedIntoAnotherTranscriptCountsOnce() async {
        let home = tempHome(), now = Date()
        let reply = #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: now - 60))","requestId":"r1","entrypoint":"cli","cwd":"/w","message":{"id":"m1","usage":{"output_tokens":40}}}"#
        write(reply + "\n", to: home + "/projects/a/original.jsonl")
        write(reply + "\n", to: home + "/projects/b/resumed.jsonl")
        let log = TranscriptLog(folder: home)
        #expect(await log.activity(at: now).outputTokens == 40)
        #expect(await log.tokens(since: now - 600, until: now) == [.terminal: 40])
    }

    @Test func weekSharesAddUpTheSamples() {
        let samples = (0..<4).map { UsageHistory.Sample(at: t0 - Double($0) * 900, load: 10, week: 10, apps: .init([.t3Code: 30, .terminal: 10])) }
        let report = WeekReport(account: sample.account(id: "cto")!, samples: samples, current: nil, at: t0)
        #expect(report.appTokens == [.t3Code: 120, .terminal: 40])
        #expect(UsageFormat.shares(report.appTokens) == "T3 Code 75% · Terminal 25%")
        #expect(UsageFormat.shares([.claudeDesktop: 1, .terminal: 1]) == "Terminal 50% · Claude desktop 50%")
    }

    @Test func samplesWrittenBeforeAppTokensStillLoad() throws {
        let history = UsageHistory(usageStore: UsageStore(registryStore: tempStore()))
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        try Data(#"{"apps":{"t3Code":7},"at":1800000000,"load":3}"#.utf8).write(to: history.directory.appendingPathComponent("a.jsonl"))
        #expect(history.samples(for: "a", since: .distantPast).first?.apps?[.t3Code] == 7)
    }
}
