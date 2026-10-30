import AccCore
import Foundation

let version = "1.0.0"

let usage = """
    acc: choose which Claude Code subscription new `claude` sessions use.

      acc                     pick an account (fzf; press 1-9 to jump)
      acc <account>           switch to it: `acc cto`, `acc 4`
      acc ls [--json]         list accounts (● = current)
      acc current [--json]    show the current account
      acc run <account> [--] [claude args]
                              run claude once on an account without switching
      acc add <id> [--label <label>] [--dir <config dir>]
                              register an account and log it in if needed
      acc login <account>     log an account in again and record its email
      acc rename <account> <label>
      acc rm <account>        unregister (its config dir is kept)
      acc doctor [--fix]      check every account is reachable and logged in
      acc dir [<account>]     print CLAUDE_CONFIG_DIR for an account (empty = default)
      acc version

    <account> is a position (1-9), an id, or any unique part of a label or email.
    In zsh, `claude @<account> …` is short for `acc run <account> …`.
    Registry: $ACC_HOME/accounts.json (default ~/.config/acc).
    """

let store = RegistryStore.standard()
let isTTY = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

func fail(_ error: AccError) -> Never {
    FileHandle.standardError.write(Data("acc: \(error)\n".utf8))
    if case .usage = error { exit(2) }
    exit(1)
}

func say(_ line: String) { print(line) }

func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func rows(_ registry: Registry) -> [String] {
    let idWidth = registry.accounts.map(\.id.count).max() ?? 0
    let labelWidth = registry.accounts.map(\.label.count).max() ?? 0
    return registry.accounts.enumerated().map { i, a in
        let mark = a.id == registry.current ? "●" : " "
        return "\(mark) \(i + 1)  \(pad(a.id, idWidth))  \(pad(a.label, labelWidth))  \(a.email ?? "")"
    }
}

func describe(_ a: Account) -> String {
    "\(a.id)  \(a.label)" + (a.email.map { "  (\($0))" } ?? "")
}

func switchTo(_ ref: String) throws {
    let registry = try store.update { r in r.current = try r.resolve(ref).id }
    say("claude → \(describe(registry.currentAccount))")
}

func which(_ name: String) -> String? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

/// Interactive pick. Returns the chosen account id, or nil if cancelled.
func pick(_ registry: Registry) throws -> String? {
    let lines = zip(registry.accounts, rows(registry)).map { "\($0.id)\t\($1)" }
    guard let fzf = which("fzf") else {
        lines.forEach { say(String($0.split(separator: "\t", maxSplits: 1)[1])) }
        FileHandle.standardOutput.write(Data("account: ".utf8))
        guard let answer = readLine(), !answer.isEmpty else { return nil }
        return try registry.resolve(answer).id
    }
    let jumps = registry.accounts.prefix(9).enumerated().map { "\($0 + 1):become(echo \($1.id))" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: fzf)
    process.arguments = [
        "--height=~\(registry.accounts.count + 4)", "--reverse", "--no-sort",
        "--delimiter=\t", "--with-nth=2..",
        "--prompt=claude account › ", "--header=new claude sessions everywhere will use it",
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

func logIn(_ account: Account, claude: Claude) throws -> Claude.AuthStatus {
    var status = try claude.authStatus(for: account)
    if !status.loggedIn {
        say("Log in to the account for '\(account.label)' in the browser window that opens.")
        let code = try claude.run(account: account, arguments: ["auth", "login"])
        guard code == 0 else { throw AccError.claudeFailed("`claude auth login` exited \(code)") }
        status = try claude.authStatus(for: account)
        guard status.loggedIn else { throw AccError.claudeFailed("still not logged in after `claude auth login`") }
    }
    return status
}

/// Per-account outcomes written from concurrentPerform's threads.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<Claude.AuthStatus, AccError>?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
    subscript(i: Int) -> Result<Claude.AuthStatus, AccError>? {
        get { lock.withLock { values[i] } }
        set { lock.withLock { values[i] = newValue } }
    }
}

func doctor(fix: Bool) throws -> Bool {
    let registry = try store.load()
    let claude = try Claude.locate()
    let results = Results(count: registry.accounts.count)
    DispatchQueue.concurrentPerform(iterations: registry.accounts.count) { i in
        let account = registry.accounts[i]
        if let dir = account.resolvedConfigDir(), !FileManager.default.fileExists(atPath: dir) {
            results[i] = .failure(.system("config dir \(dir) does not exist"))
            return
        }
        do { results[i] = .success(try claude.authStatus(for: account)) } catch {
            results[i] = .failure(error as? AccError ?? .system(error.localizedDescription))
        }
    }

    var healthy = true
    var emails: [String: String] = [:]
    let width = registry.accounts.map(\.id.count).max() ?? 0
    for (i, account) in registry.accounts.enumerated() {
        let name = pad(account.id, width)
        switch results[i]! {
        case .failure(let e):
            healthy = false
            say("✗ \(name)  \(e)")
        case .success(let s) where !s.loggedIn:
            healthy = false
            say("✗ \(name)  not logged in → acc login \(account.id)")
        case .success(let s) where s.email != account.email:
            if fix, let email = s.email { emails[account.id] = email }
            let note = fix ? "recorded" : "run acc doctor --fix to record it"
            say("! \(name)  logged in as \(s.email ?? "unknown"), registry says \(account.email ?? "nothing") (\(note))")
        case .success(let s):
            say("✓ \(name)  \(s.email ?? "")")
        }
    }
    if !emails.isEmpty {
        try store.update { r in
            for i in r.accounts.indices { if let e = emails[r.accounts[i].id] { r.accounts[i].email = e } }
        }
    }
    return healthy
}

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let command = args.isEmpty ? nil : args.removeFirst()

    switch command {
    case nil:
        let registry = try store.load()
        if isTTY {
            if let id = try pick(registry) { try switchTo(id) }
        } else {
            rows(registry).forEach(say)
        }

    case "ls", "list":
        let registry = try store.load()
        if flag("--json", in: &args) { say(try json(registry)) } else { rows(registry).forEach(say) }

    case "current":
        let account = try store.load().currentAccount
        if flag("--json", in: &args) { say(try json(account)) } else { say(describe(account)) }

    case "use":
        guard let ref = args.first else { throw AccError.usage("usage: acc use <account>") }
        try switchTo(ref)

    case "dir":
        let registry = try store.load()
        let account = try args.first.map(registry.resolve) ?? registry.currentAccount
        say(account.resolvedConfigDir() ?? "")

    case "run":
        guard !args.isEmpty else { throw AccError.usage("usage: acc run <account> [--] [claude args]") }
        let account = try store.load().resolve(args.removeFirst())
        if args.first == "--" { args.removeFirst() }
        throw try Claude.locate().exec(account: account, arguments: args)

    case "add":
        let label = try option("--label", in: &args)
        let dir = try option("--dir", in: &args)
        guard args.count == 1, let id = args.first else {
            throw AccError.usage("usage: acc add <id> [--label <label>] [--dir <config dir>]")
        }
        guard Registry.isValidID(id), !Registry.reservedIDs.contains(id) else { throw AccError.invalidID(id) }
        let existing = store.exists ? try store.load() : nil
        if existing?.account(id: id) != nil { throw AccError.duplicateID(id) }
        var account = Account(id: id, label: label ?? id, configDir: dir ?? "~/.claude-\(id)")
        if let path = account.resolvedConfigDir() {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        account.email = try logIn(account, claude: try Claude.locate()).email
        if var registry = existing {
            registry.accounts.append(account)
            try store.save(registry)
        } else {
            try store.save(Registry(current: id, accounts: [account]))
        }
        say("added \(describe(account))")

    case "login":
        guard let ref = args.first else { throw AccError.usage("usage: acc login <account>") }
        let account = try store.load().resolve(ref)
        let claude = try Claude.locate()
        let code = try claude.run(account: account, arguments: ["auth", "login"])
        guard code == 0 else { throw AccError.claudeFailed("`claude auth login` exited \(code)") }
        let status = try claude.authStatus(for: account)
        guard status.loggedIn else { throw AccError.claudeFailed("still not logged in") }
        try store.update { r in
            if let i = r.accounts.firstIndex(where: { $0.id == account.id }) { r.accounts[i].email = status.email }
        }
        say("logged in \(account.id) as \(status.email ?? "unknown")")

    case "rename":
        guard args.count >= 2 else { throw AccError.usage("usage: acc rename <account> <label>") }
        let ref = args.removeFirst()
        let label = args.joined(separator: " ")
        try store.update { r in
            let id = try r.resolve(ref).id
            r.accounts[r.accounts.firstIndex { $0.id == id }!].label = label
        }
        say("renamed to \(label)")

    case "rm":
        guard let ref = args.first else { throw AccError.usage("usage: acc rm <account>") }
        var removed: Account?
        try store.update { r in
            let account = try r.resolve(ref)
            guard account.id != r.current else {
                throw AccError.usage("'\(account.id)' is the current account; switch to another one first")
            }
            r.accounts.removeAll { $0.id == account.id }
            removed = account
        }
        if let removed {
            say("removed \(removed.id); its config dir \(removed.configDir ?? "~/.claude") was left in place")
        }

    case "doctor":
        if try !doctor(fix: flag("--fix", in: &args)) { exit(1) }

    case "version", "--version":
        say("acc \(version)")

    case "help", "-h", "--help":
        say(usage)

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
