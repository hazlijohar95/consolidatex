import Foundation

/// Config every account of a tool shares with that tool's primary account: the tool's shared
/// items are symlinked into each account's folder, and for Claude Code, user-scope MCP servers
/// (stored in each account's own state file) are mirrored from the primary.
public enum Shared {
    public enum Link: Equatable, Sendable {
        case linked
        case missing
        /// A real file or folder is in the way; acc never replaces those.
        case local
        case elsewhere(String)
    }

    public static func links(for account: Account, primary: Account, home: String = userHome()) -> [(item: String, state: Link)] {
        let source = primary.folder(home: home), target = account.folder(home: home)
        guard source != target else { return [] }
        let fm = FileManager.default
        return account.tool.spec.sharedItems.compactMap { item in
            guard fm.fileExists(atPath: source + "/" + item) else { return nil }
            let path = target + "/" + item
            if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
                return (item, canonical(dest) == canonical(source + "/" + item) ? .linked : .elsewhere(dest))
            }
            return (item, fm.fileExists(atPath: path) ? .local : .missing)
        }
    }

    /// Creates missing links. Returns the items it linked.
    @discardableResult
    public static func link(_ account: Account, primary: Account, home: String = userHome()) throws -> [String] {
        let source = primary.folder(home: home), target = account.folder(home: home)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        return try links(for: account, primary: primary, home: home).filter { $0.state == .missing }.map { item, _ in
            try FileManager.default.createSymbolicLink(atPath: target + "/" + item, withDestinationPath: source + "/" + item)
            return item
        }
    }

    public struct MCPDrift: Equatable, Sendable {
        public var missing: [String] = []
        public var extra: [String] = []
        public var different: [String] = []
    }

    public static func mcpDrift(_ account: Account, primary: Account, home: String = userHome()) -> MCPDrift {
        guard account.tool == .claude else { return MCPDrift() }
        let want = ClaudeSupport.mcpServers(primary, home: home)
        let have = ClaudeSupport.mcpServers(account, home: home)
        var drift = MCPDrift()
        drift.missing = want.keys.filter { have[$0] == nil }.sorted()
        drift.extra = have.keys.filter { want[$0] == nil }.sorted()
        drift.different = want.keys.filter { name in have[name].map { !$0.isEqual(want[name]!) } ?? false }.sorted()
        return drift
    }

    /// What differs between an account and its tool's primary, in words.
    public static func issues(_ account: Account, primary: Account, home: String = userHome()) -> [String] {
        var issues: [String] = []
        for (item, state) in links(for: account, primary: primary, home: home) {
            switch state {
            case .linked: break
            case .missing: issues.append("\(item) is not shared from \(primary.id) → acc sync")
            case .local: issues.append("keeps its own \(item) instead of \(primary.id)'s (move it aside, then acc sync)")
            case .elsewhere(let dest): issues.append("\(item) links to \(dest), not \(primary.id)'s")
            }
        }
        let drift = mcpDrift(account, primary: primary, home: home)
        if !drift.missing.isEmpty { issues.append("missing MCP servers \(drift.missing.joined(separator: ", ")) → acc sync") }
        if !drift.different.isEmpty { issues.append("MCP servers differ from \(primary.id): \(drift.different.joined(separator: ", ")) → acc sync") }
        if !drift.extra.isEmpty {
            issues.append("has MCP servers \(primary.id) lacks: \(drift.extra.joined(separator: ", ")) (add them to \(primary.id) to share, or acc sync --prune)")
        }
        return issues
    }

    /// Makes one account match its primary. Returns what it changed.
    public static func sync(_ account: Account, primary: Account, runner: Runner?, prune: Bool, home: String = userHome()) throws -> [String] {
        var changes = try link(account, primary: primary, home: home).map { "linked \($0)" }
        let drift = mcpDrift(account, primary: primary, home: home)
        guard account.tool == .claude, let runner, !(drift.missing + drift.different + (prune ? drift.extra : [])).isEmpty else { return changes }
        let wanted = ClaudeSupport.mcpServers(primary, home: home)
        for name in drift.missing + drift.different {
            try ClaudeSupport.addMCPServer(runner, name, definition: wanted[name]!, to: account)
            changes.append("MCP \(name) " + (drift.missing.contains(name) ? "added" : "updated"))
        }
        if prune {
            for name in drift.extra {
                try ClaudeSupport.removeMCPServer(runner, name, from: account)
                changes.append("MCP \(name) removed")
            }
        }
        return changes
    }

    /// Syncs every account that isn't its tool's primary to that primary, in display order: what
    /// `acc sync`, `acc setup` and the app's Sync Config run. One account failing doesn't stop the rest.
    public static func syncAll(_ registry: Registry, runners: [Tool: Runner], prune: Bool, home: String = userHome())
        -> [(account: Account, primary: Account, result: Result<[String], any Error>)] {
        registry.ordered.compactMap { account in
            guard let primary = registry.primary(for: account.tool), primary.id != account.id else { return nil }
            return (account, primary, Result { try sync(account, primary: primary, runner: runners[account.tool], prune: prune, home: home) })
        }
    }

    /// Readies an account `Registry.addNew` just listed in `registry`, before its login: creates its
    /// folder and shares its tool's primary config with it. Returns what it shared. MCP servers are
    /// added through the tool, so keep this off the main thread.
    public static func setUp(_ account: Account, in registry: Registry, runner: Runner, home: String = userHome()) throws -> [String] {
        try runner.prepare(account)
        guard let primary = registry.primary(for: account.tool), primary.id != account.id else { return [] }
        return try sync(account, primary: primary, runner: runner, prune: false, home: home)
    }
}

/// How one account stands: logged in, and sharing its tool's primary config.
public struct AccountHealth: Equatable, Sendable {
    public var loggedIn: Bool?
    public var email: String?
    public var detail: String?
    public var problems: [String]
    public var issues: [String]

    public static func check(_ account: Account, in registry: Registry, runner: Runner?) -> AccountHealth {
        var health = AccountHealth(loggedIn: nil, email: nil, detail: nil, problems: [], issues: [])
        if let dir = account.resolvedConfigDir(), !FileManager.default.fileExists(atPath: dir) {
            health.problems.append("folder \(dir) does not exist")
            return health
        }
        if let runner {
            do {
                let status = try runner.authStatus(for: account)
                health.loggedIn = status.loggedIn
                health.email = status.email
                health.detail = status.detail
                if !status.loggedIn { health.problems.append("not logged in → acc login \(account.id)") }
            } catch {
                health.problems.append(String(describing: error))
            }
        } else {
            health.problems.append("\(account.tool.spec.command) is not installed")
        }
        if let primary = registry.primary(for: account.tool), primary.id != account.id {
            health.issues = Shared.issues(account, primary: primary)
        }
        return health
    }

    /// Checks every account at once: each check runs the tool, so they overlap rather than queue.
    public static func checkAll(_ registry: Registry, runners: [Tool: Runner]) -> [String: AccountHealth] {
        let accounts = registry.accounts
        let results = Results<AccountHealth>(count: accounts.count)
        DispatchQueue.concurrentPerform(iterations: accounts.count) { i in
            results[i] = check(accounts[i], in: registry, runner: runners[accounts[i].tool])
        }
        return Dictionary(uniqueKeysWithValues: accounts.indices.map { (accounts[$0].id, results[$0]!) })
    }
}

/// Per-account results written from concurrentPerform's threads.
final class Results<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
    subscript(i: Int) -> T? {
        get { lock.withLock { values[i] } }
        set { lock.withLock { values[i] = newValue } }
    }
}
