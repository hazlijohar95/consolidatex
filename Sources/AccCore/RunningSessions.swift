import Darwin
import Foundation

/// A session of a tool running on this Mac now: the account it uses and the app that started it.
public struct RunningSession: Equatable, Sendable {
    public let pid: Int32
    public let accountID: String
    public let launcher: Launcher
}

/// The app a session belongs to: the app bundle highest among the process's ancestors, closest to
/// launchd. That is the app a person works in. A helper inside it, or a tool's own bundle further
/// down the chain (Claude desktop runs Claude Code from a claude.app of its own), reads as that app.
public struct Launcher: Hashable, Sendable {
    public let name: String
    /// The app's bundle, for its icon. Nil when no app started the session (a detached tmux, ssh).
    public let bundle: String?

    public static let background = Launcher(name: "Background", bundle: nil)
}

/// How many sessions one app runs on an account.
public struct AppCount: Equatable, Sendable {
    public let launcher: Launcher
    public let count: Int
}

/// Reads the process table for sessions of the registry's tools. The kernel lists only this user's
/// processes, and each costs one 64-byte record. Only tool processes have their arguments and
/// environment read, into one reused buffer, and only the variables their `ToolSpec` names become
/// strings; everything else there, login tokens included, is compared as bytes and dropped.
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
        var arguments = ArgumentBuffer()
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
            return RunningSession(pid: pid, accountID: accountID, launcher: launcher(among: parents))
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
        let uid = UInt32(getuid())
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let listed = Int(proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))) / MemoryLayout<pid_t>.size
        let names = specs.flatMap { spec in spec.processNames.map { (tool: spec.tool, bytes: Array($0.utf8)) } }
        var found: [pid_t: ToolProcess] = [:]
        for pid in pids.prefix(max(listed, 0)) where pid > 0 {
            guard let info = shortInfo(pid) else { continue }
            var tool = withUnsafeBytes(of: info.pbsi_comm) { raw in
                let comm = raw.prefix { $0 != 0 }
                return names.first { comm.elementsEqual($0.bytes) }?.tool
            }
            // An install that runs a file named for its version, such as Claude Code's 2.1.314, is known by its folder.
            if tool == nil, withUnsafeBytes(of: info.pbsi_comm, { isVersion($0.prefix { $0 != 0 }) }), let path = executablePath(pid) {
                tool = specs.first { $0.versionedInstallDir.map(path.contains) ?? false }?.tool
            }
            if let tool { found[pid] = ToolProcess(tool: tool, parent: pid_t(info.pbsi_ppid)) }
        }
        return found
    }

    static func isVersion(_ name: UnsafeRawBufferPointer.SubSequence) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 == UInt8(ascii: ".") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// `pid`'s parents, nearest first, up to but not including launchd.
    static func ancestors(of pid: pid_t) -> [pid_t] {
        var parents: [pid_t] = []
        var current = pid
        for _ in 0..<16 {
            guard let parent = shortInfo(current).map({ pid_t($0.pbsi_ppid) }), parent > 1 else { break }
            parents.append(parent)
            current = parent
        }
        return parents
    }

    /// The highest app bundle among a process's parents.
    static func launcher(among parents: [pid_t]) -> Launcher {
        let highest = parents.compactMap { executablePath($0).flatMap(AppInstall.appBundle(around:)) }.last
        return highest.map { Launcher(name: appNames.name(of: $0), bundle: $0) } ?? .background
    }

    private static let appNames = AppNames()

    /// Bundle path to display name, read once per app from its Info.plist alone. `Bundle(path:)`
    /// would keep each app's bundle object, and its whole parsed Info.plist, for good.
    private final class AppNames: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String: String] = [:]

        func name(of bundle: String) -> String {
            lock.withLock {
                if let name = names[bundle] { return name }
                let info = (try? Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Info.plist")))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let id = info?["CFBundleIdentifier"] as? String
                let name = knownApps.first { id?.hasPrefix($0.idPrefix) == true }?.name
                    ?? info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
                    ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                names[bundle] = name
                return name
            }
        }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Int(MAXPATHLEN)) { buffer in
            let length = Int(proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)))
            return length > 0 ? String(decoding: buffer.prefix(length), as: UTF8.self) : nil
        }
    }

    /// The short record, which `ps` also reads: unlike the full one, it's there for processes of
    /// other users too, such as the root-owned `login` between a terminal app and its shell.
    private static func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info : nil
    }

    struct Facts: Equatable {
        var variables: [String: String] = [:]
        /// The process runs with one of the flags asked about.
        var flagged = false
    }

    /// One buffer for every process's arguments and environment in a scan. Sessions measured 1 to 10 KB,
    /// so it starts at 32 KB. The kernel cuts the data to fit without saying so, so a buffer that comes
    /// back full is read again at the kernel's limit (`kern.argmax`, 1 MB); a larger buffer is refused.
    struct ArgumentBuffer {
        private var bytes = [UInt8](repeating: 0, count: 32 * 1024)

        mutating func facts(of pid: pid_t, variables: [String], flags: [String]) -> Facts? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = bytes.count
            guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
            if size == bytes.count, bytes.count < Self.limit {
                bytes = [UInt8](repeating: 0, count: Self.limit)
                size = bytes.count
                guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
            }
            return bytes.withUnsafeBytes { RunningSessions.facts(fromProcArgs: UnsafeRawBufferPointer(rebasing: $0.prefix(size)), variables: variables, flags: flags) }
        }

        static let limit: Int = {
            var argmax: Int32 = 0
            var length = MemoryLayout<Int32>.size
            return sysctlbyname("kern.argmax", &argmax, &length, nil, 0) == 0 ? Int(argmax) : 256 * 1024
        }()
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
}
