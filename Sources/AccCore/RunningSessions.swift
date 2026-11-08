import Foundation

/// A session of a tool running on this computer now: the account it uses and the app that started it.
public struct RunningSession: Equatable, Sendable {
    public let pid: Int32
    public let accountID: String
    public let launcher: Launcher
}

/// The app a session belongs to, the one a person works in. On macOS it's the app bundle highest
/// among the process's ancestors, closest to launchd, so a helper inside it, or a tool's own bundle
/// further down the chain (Claude desktop runs Claude Code from a claude.app of its own), reads as
/// that app. On Linux it's the desktop app whose systemd unit the session runs in.
public struct Launcher: Hashable, Sendable {
    public let name: String
    /// The app's bundle path on macOS, its desktop app ID on Linux, for its icon. Nil when no app
    /// started the session (a detached tmux, ssh).
    public let bundle: String?

    public static let background = Launcher(name: "Background", bundle: nil)
}

/// How many sessions one app runs on an account.
public struct AppCount: Equatable, Sendable {
    public let launcher: Launcher
    public let count: Int
}

/// Reads the process table (`ProcessTable`, one per platform) for sessions of the registry's tools.
/// Only tool processes have their arguments and environment read, into one reused buffer, and only
/// the variables their `ToolSpec` names become strings; everything else there, login tokens
/// included, is compared as bytes and dropped.
public enum RunningSessions {
    /// Apps whose bundle ids differ from what people call them. Past transcripts name the same apps
    /// by `Origin`, so the names are shared.
    static let knownApps: [(idPrefix: String, name: String)] = [
        ("com.superlogical.rex", "Rex"),
        ("com.t3tools.t3code", Origin.t3Code.name),
        ("com.anthropic.claudefordesktop", Origin.claudeDesktop.name),
    ]

    /// `logins` gives each account's login, for sessions that name a login rather than a folder.
    /// It's read only when such a session is running.
    public static func scan(_ registry: Registry, logins: () -> [String: Identity.Login], home: String = userHome()) -> [RunningSession] {
        let processes = toolProcesses(registry.tools.map(\.spec))
        guard !processes.isEmpty else { return [] }
        let folders = registry.accounts.reduce(into: [Tool: [String?: String]]()) { map, account in
            map[account.tool, default: [:]][account.resolvedConfigDir(home: home).map(canonical)] = account.id
        }
        var arguments = ProcessTable.ArgumentReader()
        var accountByLogin: [Identity.Login: String]?
        let ourselves = getpid()
        return processes.compactMap { pid, process in
            let spec = process.tool.spec
            // A wrapper that execs the real binary under the same name is one session with it. A
            // session started further down, from a shell inside another session, is its own.
            guard processes[process.parent]?.tool != process.tool,
                  let facts = arguments.facts(of: pid, variables: [spec.variable] + [spec.loginVariables?.account, spec.loginVariables?.organization].compactMap { $0 },
                                              flags: spec.ignoredArguments),
                  !facts.flagged
            else { return nil }
            let folder = facts.variables[spec.variable].flatMap { $0.isEmpty ? nil : canonical($0) }
            let accountID: String?
            if folder == nil, let names = spec.loginVariables, let user = facts.variables[names.account] {
                if accountByLogin == nil { accountByLogin = loginIndex(logins()) }
                accountID = accountByLogin?[Identity.Login(account: user, organization: facts.variables[names.organization])]
                    ?? accountByLogin?[Identity.Login(account: user, organization: nil)]
            } else {
                accountID = folders[process.tool]?[folder] ?? nil
            }
            guard let accountID else { return nil }
            let parents = ancestors(of: pid)
            // What this process started, such as the app's own `codex app-server`, is nobody's session.
            guard !parents.contains(ourselves) else { return nil }
            return RunningSession(pid: pid, accountID: accountID, launcher: ProcessTable.launcher(of: pid, parents: parents))
        }
        .sorted { $0.pid < $1.pid }
    }

    /// Accounts by exact login, plus, for a user id only one account has, by that id alone: a
    /// session or a state file that lacks the organization still finds its account.
    static func loginIndex(_ logins: [String: Identity.Login]) -> [Identity.Login: String] {
        var index = Dictionary(logins.map { ($1, $0) }) { first, _ in first }
        for (user, accounts) in Dictionary(grouping: logins, by: \.value.account) where accounts.count == 1 {
            index[Identity.Login(account: user, organization: nil)] = index[Identity.Login(account: user, organization: nil)] ?? accounts[0].key
        }
        return index
    }

    /// Sessions grouped by app, busiest first, then by name, so the order is the same every time.
    public static func byApp(_ sessions: [RunningSession]) -> [AppCount] {
        Dictionary(grouping: sessions, by: \.launcher).map { AppCount(launcher: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.launcher.name) > ($1.count, $0.launcher.name) }
    }

    struct ToolProcess {
        let tool: Tool
        let parent: pid_t
    }

    /// This user's processes that are a tool, by pid.
    static func toolProcesses(_ specs: [ToolSpec]) -> [pid_t: ToolProcess] {
        let names = specs.flatMap { spec in spec.processNames.map { (tool: spec.tool, bytes: Array($0.utf8)) } }
        var found: [pid_t: ToolProcess] = [:]
        ProcessTable.forEachUserProcess { pid, parent, name in
            var tool = names.first { name.elementsEqual($0.bytes) }?.tool
            // An install that runs a file named for its version, such as Claude Code's 2.1.314, is known by its folder.
            if tool == nil, isVersion(name), let path = ProcessTable.executablePath(pid) {
                tool = specs.first { $0.versionedInstallDir.map(path.contains) ?? false }?.tool
            }
            if let tool { found[pid] = ToolProcess(tool: tool, parent: parent) }
        }
        return found
    }

    static func isVersion(_ name: some Collection<UInt8>) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 == UInt8(ascii: ".") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// `pid`'s parents, nearest first, up to but not including the first process (launchd, init).
    static func ancestors(of pid: pid_t) -> [pid_t] {
        var parents: [pid_t] = []
        var current = pid
        for _ in 0..<16 {
            guard let parent = ProcessTable.parent(of: current), parent > 1 else { break }
            parents.append(parent)
            current = parent
        }
        return parents
    }

    /// App names by bundle path or app ID, worked out once per app.
    final class AppNames: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String: String] = [:]
        private let lookUp: @Sendable (String) -> String

        init(_ lookUp: @escaping @Sendable (String) -> String) { self.lookUp = lookUp }

        func name(of app: String) -> String {
            lock.withLock {
                if let name = names[app] { return name }
                let name = lookUp(app)
                names[app] = name
                return name
            }
        }
    }

    struct Facts: Equatable {
        var variables: [String: String] = [:]
        /// The process runs with one of the flags asked about.
        var flagged = false
    }

    /// KERN_PROCARGS2 is argc, the executable path, NUL padding, then argc arguments and the
    /// `NAME=value` strings, each ending in one NUL. An empty argument ("") is a lone NUL, so only the
    /// padding is skipped as a run. Only the arguments and variables asked about are looked at.
    static func facts(fromProcArgs bytes: UnsafeRawBufferPointer, variables: [String], flags: [String] = []) -> Facts {
        guard bytes.count > 4 else { return Facts() }
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        var facts = Facts()
        var index = 4
        func nextString() -> UnsafeRawBufferPointer.SubSequence? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            defer { index += 1 }
            return bytes[start..<index]
        }
        _ = nextString()  // the executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        let flagBytes = flags.map { Array($0.utf8) }
        for _ in 0..<argc {
            guard let argument = nextString() else { return facts }
            if flagBytes.contains(where: { argument.elementsEqual($0) }) { facts.flagged = true }
        }
        let wanted = variables.map { (name: $0, prefix: Array("\($0)=".utf8)) }
        // The environment ends at the first empty string, where only NUL padding follows.
        while let entry = nextString(), !entry.isEmpty {
            for variable in wanted where entry.starts(with: variable.prefix) {
                facts.variables[variable.name] = String(decoding: entry.dropFirst(variable.prefix.count), as: UTF8.self)
            }
        }
        return facts
    }

    /// Linux keeps a process's arguments in /proc/<pid>/cmdline and its `NAME=value` environment in
    /// /proc/<pid>/environ, each string ending in one NUL. Only the arguments and variables asked
    /// about are looked at.
    static func facts(cmdline: UnsafeRawBufferPointer, environ: UnsafeRawBufferPointer, variables: [String], flags: [String] = []) -> Facts {
        var facts = Facts()
        let flagBytes = flags.map { Array($0.utf8) }
        for argument in cmdline.split(separator: 0, omittingEmptySubsequences: false)
        where flagBytes.contains(where: { argument.elementsEqual($0) }) {
            facts.flagged = true
        }
        let wanted = variables.map { (name: $0, prefix: Array("\($0)=".utf8)) }
        for entry in environ.split(separator: 0) {
            for variable in wanted where entry.starts(with: variable.prefix) {
                facts.variables[variable.name] = String(decoding: entry.dropFirst(variable.prefix.count), as: UTF8.self)
            }
        }
        return facts
    }

    /// The desktop app ID in a /proc/<pid>/cgroup, from the unit a desktop session starts each app in,
    /// per systemd's desktop environment conventions, which uwsm, GNOME and KDE follow:
    /// `app[-<launcher>]-<app id>[@<random>].service` or `app[-<launcher>]-<app id>-<random>.scope`.
    /// The launcher and app ID write their own dashes as `\x2d`. The innermost such unit is the app.
    /// Terminals that start each tab in a scope of their own, as GNOME's VTE terminals do, put those
    /// in an `app-<app id>.slice`, which names the app when no unit does.
    static func appID(fromCgroup cgroup: String) -> String? {
        let parts = cgroup.split { $0 == "/" || $0 == "\n" }
        if let slice = parts.last(where: { $0.hasPrefix("app-") && $0.hasSuffix(".slice") && $0 != "app-graphical.slice" }),
           !parts.contains(where: { $0.hasPrefix("app-") && ($0.hasSuffix(".service") || $0.hasSuffix(".scope")) }) {
            let id = unescapingUnitName(slice.dropFirst("app-".count).dropLast(".slice".count))
            return id.isEmpty ? nil : id
        }
        let unit = parts.last { $0.hasPrefix("app-") && ($0.hasSuffix(".service") || $0.hasSuffix(".scope")) }
        guard var name = unit.map({ String($0.dropFirst("app-".count)) }) else { return nil }
        if name.hasSuffix(".service") {
            name = String(name.dropLast(".service".count).prefix { $0 != "@" })
        } else {
            name = String(name.dropLast(".scope".count))
            guard let random = name.lastIndex(of: "-") else { return nil }
            name = String(name[..<random])
        }
        // A launcher, then the ID. A unit that left a dash in its ID unescaped keeps it.
        let words = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let id = unescapingUnitName(words.count == 2 ? words[1] : words[0])
        return id.isEmpty ? nil : id
    }

    /// systemd's `\xNN` escapes in a unit name, decoded.
    static func unescapingUnitName(_ name: Substring) -> String {
        var bytes: [UInt8] = []
        var rest = name.utf8
        while let byte = rest.first {
            let hex = rest.dropFirst(2).prefix(2)
            if byte == UInt8(ascii: "\\"), rest.dropFirst().first == UInt8(ascii: "x"), hex.count == 2,
               let value = UInt8(String(decoding: hex, as: UTF8.self), radix: 16) {
                bytes.append(value)
                rest = rest.dropFirst(4)
            } else {
                bytes.append(byte)
                rest = rest.dropFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The `Name` in a desktop entry's `[Desktop Entry]` group; translations (`Name[de]=`) aren't it.
    /// Space around the `=` doesn't count, as the spec says.
    static func desktopEntryName(_ contents: String) -> String? {
        var inEntry = false
        for line in contents.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEntry = line == "[Desktop Entry]"
            } else if inEntry, let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces) == "Name" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
