import AccCore
import Foundation

let version = "2.0.0"

let usage = """
    acc: run several subscriptions of Claude Code, Codex and opencode side by side.

      acc setup [--yes]          first run: import existing accounts, hook up your shell
      acc                        pick an account (fzf; 1-9 jump)
      acc <account>              make it the account new sessions of its tool use
      acc <tool> [<account>]     same, among one tool's accounts (acc codex work)
      acc ls [<tool>] [--json]   list accounts with last-seen usage (● = current)
      acc auto [<tool>]          switch to the account with the most quota left
      acc report                 the last 7 days: weekly use and hours capped, per account
      acc continue [<account>] [--session <id>]
                                 resume this folder's latest conversation on another account
                                 (default: the roomiest); Claude Code and Codex
      acc run <account> [--] [args]
                                 run the account's tool once on it, without switching
      acc add <tool> [<name>] [--id <id>] [--dir <folder>]
                                 add a subscription: new folder, shared config, login
      acc login <account>        log an account in again
      acc rename <account> <name> / acc rm <account>
      acc doctor [--fix]         check logins, shared config and setup
      acc sync [--prune]         share each tool's config from its primary account
      acc ui                     open the Consolidatex window
      acc version

    Tools: claude, codex, opencode. After `acc setup`, typing `claude`, `codex` or `opencode`
    starts the current account, and `claude @work …` runs one session on another.
    <account> is a position, an id, or any unique part of a name or email.
    """

let store = RegistryStore.standard()
let usages = Usages(store: UsageStore(registryStore: store))
let environment = ProcessInfo.processInfo.environment
let isTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

func fail(_ error: AccError) -> Never {
    FileHandle.standardError.write(Data("acc: \(error)\n".utf8))
    if case .usage = error { exit(2) }
    exit(1)
}

func say(_ line: String = "") { print(line) }
func warn(_ line: String) { FileHandle.standardError.write(Data("acc: \(line)\n".utf8)) }

func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func tool(named name: String) -> Tool? { Tool.allCases.first { $0.rawValue == name || $0.spec.command == name } }

func rows(_ registry: Registry, tool: Tool? = nil) -> [(Account, String)] {
    let shown = registry.ordered.filter { tool == nil || $0.tool == tool }
    let usage = usages.all(registry)
    let running = Dictionary(grouping: RunningSessions.scan(registry, logins: { ClaudeSupport.logins(in: registry) }), by: \.accountID)
    let w = (id: shown.map(\.id.count).max() ?? 0, label: shown.map(\.label.count).max() ?? 0,
             email: shown.map { ($0.email ?? "").count }.max() ?? 0)
    return shown.map { a in
        let position = registry.ordered.firstIndex(of: a)! + 1
        let mark = registry.isCurrent(a) ? "●" : " "
        let line = "\(mark) \(position)  \(pad(a.tool.rawValue, 8))  \(pad(a.id, w.id))  \(pad(a.label, w.label))  \(pad(a.email ?? "", w.email))  \(UsageFormat.summary(usage[a.id], tool: a.tool))" + runningNote(running[a.id] ?? [])
        return (a, line)
    }
}

/// "  · running in Rex ×2, T3 Code", or nothing.
func runningNote(_ sessions: [RunningSession]) -> String {
    sessions.isEmpty ? "" : "  · running in " + UsageFormat.running(RunningSessions.byApp(sessions))
}

func describe(_ a: Account) -> String {
    "\(a.tool.spec.name): \(a.id)  \(a.label)" + (a.email.map { "  (\($0))" } ?? "")
}

func switchTo(_ ref: String, tool: Tool? = nil) throws {
    let chosen = try store.update { r in
        let account = try r.resolve(ref, tool: tool)
        try r.use(account.id)
        return account
    }
    say("\(chosen.tool.spec.command) → \(describe(chosen))")
}

/// Interactive pick. Returns the chosen account id, or nil if cancelled.
func pick(_ registry: Registry, tool: Tool?) throws -> String? {
    let lines = rows(registry, tool: tool).map { "\($0.0.id)\t\($0.1)" }
    guard !lines.isEmpty else { throw AccError.usage("no accounts yet (run: acc setup)") }
    guard let fzf = Runner.which("fzf") else {
        lines.forEach { say(String($0.split(separator: "\t", maxSplits: 1)[1])) }
        FileHandle.standardOutput.write(Data("account: ".utf8))
        guard let answer = readLine(), !answer.isEmpty else { return nil }
        return try registry.resolve(answer, tool: tool).id
    }
    let jumps = registry.ordered.prefix(9).enumerated()
        .filter { tool == nil || $1.tool == tool }
        .map { "\($0 + 1):become(echo \($1.id))" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fzf)
    process.arguments = [
        "--height=~\(lines.count + 4)", "--reverse", "--no-sort", "--delimiter=\t", "--with-nth=2..",
        "--prompt=account › ", "--header=new sessions of that tool, in every terminal, will use it",
        "--bind=\(jumps.joined(separator: ","))",
    ]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(Data(lines.joined(separator: "\n").utf8))
    try input.fileHandleForWriting.close()
    let chosen = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return chosen.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Pulls `--name value` out of args.
func option(_ name: String, in args: inout [String]) throws -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { throw AccError.usage("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}

func flag(_ name: String, in args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

/// Logs the account in if it is not already, and returns its status.
func ensureLoggedIn(_ account: Account, runner: Runner) throws -> Runner.AuthStatus {
    var status = try runner.authStatus(for: account)
    if !status.loggedIn {
        say("Log in to \(account.tool.spec.name) for '\(account.label)'.")
        if let hint = account.tool.spec.loginHint { say(hint) }
        let code = try runner.run(account: account, arguments: account.tool.spec.loginArguments)
        guard code == 0 else { throw AccError.toolFailed(runner.spec.command, "login exited \(code)") }
        status = try runner.authStatus(for: account)
        guard status.loggedIn else { throw AccError.toolFailed(runner.spec.command, "still not logged in after login") }
    }
    return status
}

func doctor(fix: Bool) throws -> Bool {
    let registry = try store.load()
    let health = AccountHealth.checkAll(registry, runners: Runner.locateAll())
    var healthy = true
    var emails: [String: String] = [:]
    let width = registry.accounts.map(\.id.count).max() ?? 0
    for account in registry.ordered {
        let h = health[account.id]!
        let name = pad(account.id, width)
        if !h.problems.isEmpty {
            healthy = false
            h.problems.forEach { say("✗ \(name)  \($0)") }
        } else if let email = h.email, email != account.email {
            if fix { emails[account.id] = email }
            say("! \(name)  logged in as \(email), registry says \(account.email ?? "nothing") (\(fix ? "recorded" : "acc doctor --fix records it"))")
        } else {
            say("✓ \(name)  \(account.tool.spec.name)  \(h.email ?? h.detail ?? "logged in")")
        }
        h.issues.forEach { say("! \(name)  \($0)") }
    }
    if let shell = ShellInit.Shell.from(path: environment["SHELL"]) {
        if !ShellInit.isInstalled(shell) {
            say("! shell     \(shell.rawValue) hook not installed, so `claude`/`codex`/`opencode` ignore acc → acc setup")
        }
    }
    if case .outdated(let installed, let old, _) = appStatus() {
        say("! app       \(abbreviatingHome(installed)) is \(old ?? "older"), acc is \(version) → acc setup")
    }
    if !emails.isEmpty { try store.update { r in for (id, email) in emails { r.recordEmail(email, for: id) } } }
    return healthy
}

func statusLine() {
    let input = (try? JSONDecoder().decode(StatusInput.self, from: FileHandle.standardInput.readDataToEndOfFile())) ?? .empty
    guard let registry = try? store.load() else {
        print("✳ acc: registry problem, run acc doctor")
        return
    }
    let now = Date()
    let account = registry.account(for: .claude, configDir: environment["CLAUDE_CONFIG_DIR"])
    // Claude Code runs this on every update, so each account's file is read once.
    var claude = usages.all(registry, tool: .claude)
    if let live = input.usage(at: now), let account {
        claude[account.id] = (try? usages.store.merge(live, over: claude[account.id], for: account.id, at: now)) ?? live
    }
    let suggestion = registry.roomiest(.claude, claude, excluding: account?.id, at: now)
    print(StatusLine.render(account: account, usage: account.flatMap { claude[$0.id] }, input: input, suggestion: suggestion, now: now))
}

/// Starts a tool on its current account. The shell functions from `acc shell-init` call this.
/// Never stops the tool from starting: with no registry it runs the tool untouched.
func launch(_ tool: Tool, _ arguments: [String]) throws -> Never {
    var args = arguments
    let runner = try Runner.locate(tool)
    // `@account` is asked for on this command line, so it beats a variable inherited from a parent session.
    if let first = args.first, first.hasPrefix("@"), first.count > 1 {
        let account = try store.load().resolve(String(first.dropFirst()), tool: tool)
        args.removeFirst()
        throw runner.exec(account: account, arguments: args)
    }
    if let pinned = environment[tool.spec.variable], !pinned.isEmpty { throw runner.exec(account: nil, arguments: args) }
    let registry: Registry
    do {
        registry = try store.load()
    } catch AccError.registryMissing {
        throw runner.exec(account: nil, arguments: args)
    } catch {
        warn("\(error)\nacc: starting \(tool.spec.command) on its default account instead (run: acc doctor)")
        throw runner.exec(account: nil, arguments: args)
    }
    throw runner.exec(account: registry.current(for: tool), arguments: args)
}

func continueSession(_ ref: String?, sessionID: String?) throws -> Never {
    let registry = try store.load()
    let cwd = FileManager.default.currentDirectoryPath
    let named = try ref.map { try registry.resolve($0) }
    if let named, !Sessions.supports(named.tool) {
        throw AccError.usage("\(named.tool.spec.name) conversations cannot move between accounts")
    }
    let sessions = Sessions.forProject(cwd, in: registry, tool: named?.tool)
    let candidates = sessionID.map { id in sessions.filter { $0.id.hasPrefix(id) } } ?? sessions
    guard let session = candidates.first else {
        throw AccError.usage(sessionID.map { "no conversation \($0) for \(cwd)" } ?? "no Claude Code or Codex conversation found for \(cwd)")
    }
    let tool = session.account.tool
    guard let target = named ?? registry.roomiest(tool, usages.all(registry), excluding: session.account.id) else {
        throw AccError.usage("every other \(tool.spec.name) account is near its limit; name one: acc continue <account>")
    }
    if target.id != session.account.id { try Sessions.copy(session, to: target) }
    let age = UsageFormat.relative(Date(), from: session.modified).replacingOccurrences(of: "in ", with: "")
    warn("↪ continuing \(session.id.prefix(8)) (last active \(age) ago on \(session.account.id)) on \(target.id)")
    throw try Runner.locate(tool).exec(account: target, arguments: Sessions.resumeArguments(session))
}

/// The last 7 days per account, from the history the menu bar app records while it runs.
func report() throws {
    let registry = try store.load()
    let history = UsageHistory(usageStore: usages.store)
    let now = Date()
    let reports = registry.ordered.map { a in
        WeekReport(account: a, samples: history.samples(for: a.id, since: now - WeekReport.span), current: usages.usage(for: a), at: now)
    }
    guard reports.contains(where: { $0.coveredHours > 0 }) else {
        throw AccError.usage("not enough history yet: the Consolidatex menu bar app records usage every 15 minutes while it runs")
    }
    let width = reports.map(\.account.id.count).max() ?? 0
    say("Last 7 days")
    for r in reports {
        let week = r.weekUsed.map { "week \(Int($0.rounded()))%" } ?? "no weekly limit"
        let capped = r.cappedHours >= 0.5 ? "capped \(Int(r.cappedHours.rounded()))h" : "never capped"
        let apps = UsageFormat.shares(r.appTokens, limit: 3) ?? ""
        say("  \(pad(r.account.tool.rawValue, 8))  \(pad(r.account.id, width))  \(pad(week, 15))  \(pad(capped, 12))  \(pad(apps, 40))  \(r.note ?? "")")
    }
    let covered = reports.map(\.coveredHours).max() ?? 0
    if covered < 24 * 6 { say("\nHistory covers \(Int(covered.rounded()))h of the week so far.") }
}

// MARK: setup

func ask(_ question: String, assumeYes: Bool) -> Bool {
    if assumeYes { say("\(question) yes"); return true }
    guard isTTY else { say("\(question) skipped (not interactive; rerun with --yes)"); return false }
    FileHandle.standardOutput.write(Data("\(question) [Y/n] ".utf8))
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    return answer.isEmpty || answer == "y" || answer == "yes"
}

func runCommand(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

func appStatus() -> AppInstall.Status {
    AppInstall.status(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
}

/// Puts the menu bar app in ~/Applications (Homebrew builds it inside its keg), then offers to open it.
func setupApp(assumeYes: Bool) throws {
    var app: String?
    switch appStatus() {
    case .notBundled:
        return
    case .inPlace(let path), .current(let path):
        app = path
    case .missing(let bundle):
        if ask("\nAdd the Consolidatex menu bar app to ~/Applications?", assumeYes: assumeYes) { app = try AppInstall.install(bundle) }
    case .outdated(let installed, let old, let bundle):
        if ask("\nUpdate \(abbreviatingHome(installed)) from \(old ?? "an older version") to \(version)?", assumeYes: assumeYes) {
            runCommand("/usr/bin/pkill", ["-x", "Consolidatex"])
            app = try AppInstall.install(bundle, to: installed)
        }
    }
    if let app, ask("Open it now?", assumeYes: assumeYes) { runCommand("/usr/bin/open", [app]) }
}

func setup(assumeYes: Bool) throws {
    say("Consolidatex setup\n")
    let installed = Array(Runner.locateAll().keys)
    for tool in Tool.allCases {
        say(installed.contains(tool) ? "  ✓ \(tool.spec.name)" : "  – \(tool.spec.name) (not installed)")
    }

    var registry = try store.loadOrEmpty()
    let candidates = Discovery.find(excluding: registry).filter { installed.contains($0.tool) }
    if candidates.isEmpty {
        say(registry.accounts.isEmpty ? "\nNo existing accounts found. Add one with: acc add <tool>" : "\nNo new accounts to import.")
    } else {
        say("\nFound \(candidates.count) account\(candidates.count == 1 ? "" : "s"):")
        candidates.forEach { say("  \(pad($0.tool.spec.name, 12)) \(pad($0.label, 24)) \($0.configDir ?? "default folder")") }
        if ask("Import them?", assumeYes: assumeYes) {
            for c in candidates {
                let account = try registry.adopt(c)
                say("  + \(account.id)  \(account.label)\(account.email.map { "  (\($0))" } ?? "")")
            }
            try store.save(registry)
        }
    }

    if let shell = ShellInit.Shell.from(path: environment["SHELL"]) {
        let file = abbreviatingHome(shell.hook().file)
        if ask("\nAdd the \(shell.rawValue) hook to \(file), so `claude`, `codex` and `opencode` start on the account you pick?", assumeYes: assumeYes) {
            switch try ShellInit.installHook(shell) {
            case .alreadyInstalled: say("  already there")
            case .installed: say("  added; open a new terminal to use it")
            case .replacedLegacy: say("  replaced the older acc line; open a new terminal to use it")
            }
        }
    } else {
        say("\nUnknown shell \(environment["SHELL"] ?? "?"). Add `eval \"$(acc shell-init zsh|bash)\"` or `acc shell-init fish | source` yourself.")
    }

    if let primary = registry.primary(for: .claude) {
        if ask("\nShow each Claude Code session's account and usage in its status line?", assumeYes: assumeYes) {
            switch try StatusLineSetup.install(for: primary, acc: Runner.which("acc") ?? CommandLine.arguments[0]) {
            case .alreadyInstalled: say("  already on")
            case .installed: say("  on (applies to every Claude account sharing \(primary.id)'s settings)")
            case .otherStatusLine(let existing): say("  left alone: you already use `\(existing)`")
            }
        }
    }

    let drifting = registry.accounts.filter { a in
        registry.primary(for: a.tool).map { $0.id != a.id && !Shared.issues(a, primary: $0).isEmpty } ?? false
    }
    if !drifting.isEmpty, ask("\n\(drifting.count) account\(drifting.count == 1 ? "" : "s") don't share config (rules, settings, skills, MCP servers) with their tool's primary. Share it?", assumeYes: assumeYes) {
        for account in drifting {
            let primary = registry.primary(for: account.tool)!
            let changes = try Shared.sync(account, primary: primary, runner: try? Runner.locate(account.tool), prune: false)
            if !changes.isEmpty { say("  \(account.id): \(changes.joined(separator: ", "))") }
        }
    }

    try setupApp(assumeYes: assumeYes)

    say("\nDone. In a new terminal:")
    say("  acc            pick accounts")
    say("  claude / codex / opencode   start on the current account")
    say("  acc doctor     check everything")
}

// MARK: commands

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let command = args.isEmpty ? nil : args.removeFirst()

    switch command {
    case nil:
        let registry = try store.load()
        if isTTY {
            if let id = try pick(registry, tool: nil) { try switchTo(id) }
        } else {
            rows(registry).forEach { say($0.1) }
        }

    case "ls", "list":
        let asJSON = flag("--json", in: &args)
        let registry = try store.load()
        if asJSON { say(try json(registry)) } else { rows(registry, tool: args.first.flatMap(tool(named:))).forEach { say($0.1) } }

    case "current":
        let asJSON = flag("--json", in: &args)
        let registry = try store.load()
        let accounts = (args.first.flatMap(tool(named:)).map { [$0] } ?? registry.tools).compactMap(registry.current(for:))
        if asJSON { say(try json(accounts)) } else { accounts.forEach { say(describe($0)) } }

    case "use":
        guard let ref = args.first else { throw AccError.usage("usage: acc use <account>") }
        try switchTo(ref)

    case "auto":
        let registry = try store.load()
        let usage = usages.all(registry)
        let tools = args.first.flatMap(tool(named:)).map { [$0] } ?? registry.tools.filter { t in registry.accounts(for: t).contains { usage[$0.id] != nil } }
        guard !tools.isEmpty else { throw AccError.usage("no usage recorded yet; use your accounts for a while first") }
        for t in tools {
            if let best = registry.byHeadroom(t, usage).first {
                try switchTo(best.id)
                say("  \(UsageFormat.summary(usage[best.id], tool: t))")
            }
        }

    case "report":
        try report()

    case "continue":
        let session = try option("--session", in: &args)
        try continueSession(args.first, sessionID: session)

    case "launch":
        guard let name = args.first, let t = tool(named: name) else { throw AccError.usage("usage: acc launch <tool> [--] [args]") }
        args.removeFirst()
        if args.first == "--" { args.removeFirst() }
        try launch(t, args)

    case "run":
        guard !args.isEmpty else { throw AccError.usage("usage: acc run <account> [--] [args]") }
        let account = try store.load().resolve(args.removeFirst())
        if args.first == "--" { args.removeFirst() }
        throw try Runner.locate(account.tool).exec(account: account, arguments: args)

    case "dir":
        let registry = try store.load()
        let account = try args.first.map { try registry.resolve($0) } ?? registry.current(for: .claude)
        say(account?.resolvedConfigDir() ?? "")

    case "add":
        let id = try option("--id", in: &args)
        let dir = try option("--dir", in: &args)
        guard let name = args.first, let t = tool(named: name) else {
            throw AccError.usage("usage: acc add <claude|codex|opencode> [<name>] [--id <id>] [--dir <folder>]")
        }
        args.removeFirst()
        var registry = try store.loadOrEmpty()
        let label = args.isEmpty ? "\(t.spec.name) \(registry.accounts(for: t).count + 1)" : args.joined(separator: " ")
        var account = registry.newAccount(tool: t, label: label, id: id)
        if let dir { account.configDir = dir }
        var next = registry
        try next.add(account)
        let runner = try Runner.locate(t)
        try runner.prepare(account)
        if let primary = registry.primary(for: t) {
            for change in try Shared.sync(account, primary: primary, runner: runner, prune: false) { say("  \(change)") }
        }
        account.email = try ensureLoggedIn(account, runner: runner).email
        try registry.add(account)
        try store.save(registry)
        say("added \(describe(account))")

    case "login":
        guard let ref = args.first else { throw AccError.usage("usage: acc login <account>") }
        let account = try store.load().resolve(ref)
        let runner = try Runner.locate(account.tool)
        if let hint = account.tool.spec.loginHint { say(hint) }
        let code = try runner.run(account: account, arguments: account.tool.spec.loginArguments)
        guard code == 0 else { throw AccError.toolFailed(runner.spec.command, "login exited \(code)") }
        let status = try runner.authStatus(for: account)
        guard status.loggedIn else { throw AccError.toolFailed(runner.spec.command, "still not logged in") }
        try store.update { $0.recordEmail(status.email, for: account.id) }
        say("logged in \(account.id)" + (status.email.map { " as \($0)" } ?? ""))

    case "rename":
        guard args.count >= 2 else { throw AccError.usage("usage: acc rename <account> <name>") }
        let ref = args.removeFirst()
        let label = args.joined(separator: " ")
        try store.update { r in try r.rename(r.resolve(ref).id, to: label) }
        say("renamed to \(label)")

    case "rm":
        guard let ref = args.first else { throw AccError.usage("usage: acc rm <account>") }
        let removed = try store.update { r in
            let account = try r.resolve(ref)
            try r.remove(account.id)
            return account
        }
        say("removed \(removed.id); its folder \(removed.folder()) was left in place")

    case "doctor":
        if try !doctor(fix: flag("--fix", in: &args)) { exit(1) }

    case "sync":
        let prune = flag("--prune", in: &args)
        let registry = try store.load()
        var changed = false
        for account in registry.ordered {
            guard let primary = registry.primary(for: account.tool), primary.id != account.id else { continue }
            let changes = try Shared.sync(account, primary: primary, runner: try? Runner.locate(account.tool), prune: prune)
            if !changes.isEmpty { say("\(account.id): \(changes.joined(separator: ", "))"); changed = true }
            for issue in Shared.issues(account, primary: primary) { say("! \(account.id): \(issue)") }
        }
        if !changed { say("everything already shares its primary's config") }

    case "setup":
        try setup(assumeYes: flag("--yes", in: &args))

    case "shell-init":
        guard let name = args.first, let shell = ShellInit.Shell(rawValue: name) else {
            throw AccError.usage("usage: acc shell-init zsh|bash|fish")
        }
        print(ShellInit.script(for: shell), terminator: "")

    case "statusline":
        statusLine()

    case "ui":
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["consolidatex://manage"]
        try open.run()
        open.waitUntilExit()
        if open.terminationStatus != 0 { throw AccError.system("could not open Consolidatex; is the app installed?") }

    case "version", "--version":
        say("acc \(version)")

    case "help", "-h", "--help":
        say(usage)

    case let word? where tool(named: word) != nil:
        let t = tool(named: word)!
        let registry = try store.load()
        if let ref = args.first {
            try switchTo(ref, tool: t)
        } else if isTTY {
            if let id = try pick(registry, tool: t) { try switchTo(id) }
        } else {
            rows(registry, tool: t).forEach { say($0.1) }
        }

    case let ref?:
        if ref.hasPrefix("-") { throw AccError.usage(usage) }
        try switchTo(ref)
    }
}

do {
    try main()
} catch let error as AccError {
    fail(error)
} catch {
    fail(.system(error.localizedDescription))
}
