import Foundation

/// One subscription of one tool. `configDir == nil` means the tool's default folder, which
/// must run with the tool's variable unset: for Claude Code, pointing CLAUDE_CONFIG_DIR at
/// ~/.claude selects a different config file and keychain entry than leaving it unset.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var tool: Tool
    public var label: String
    public var configDir: String?
    public var email: String?

    public init(id: String, tool: Tool, label: String, configDir: String?, email: String? = nil) {
        self.id = id
        self.tool = tool
        self.label = label
        self.configDir = configDir
        self.email = email
    }

    /// The value for the tool's variable, or nil to leave it unset.
    public func resolvedConfigDir(home: String = userHome()) -> String? { Self.resolve(configDir, home: home) }

    /// A `configDir` as written in the registry, with "~" expanded; nil stays nil (the default folder).
    public static func resolve(_ configDir: String?, home: String = userHome()) -> String? {
        guard let configDir else { return nil }
        if configDir == "~" { return home }
        if configDir.hasPrefix("~/") { return home + configDir.dropFirst(1) }
        return configDir
    }

    /// The folder holding this account's files, default or not.
    public func folder(home: String = userHome()) -> String {
        resolvedConfigDir(home: home) ?? home + "/" + tool.spec.defaultDir
    }
}

public struct Registry: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    /// Words acc treats as subcommands or tool names, so they can never be account ids.
    public static let reservedIDs: Set<String> = Set(Tool.allCases.map(\.rawValue) + [
        "add", "auto", "continue", "current", "dir", "doctor", "help", "launch", "login", "ls", "list",
        "rename", "report", "rm", "run", "setup", "shell-init", "statusline", "sync", "ui", "use", "version", "kiro",
    ])

    /// A folder `acc rm` took out of the list, so discovery doesn't bring it back.
    public struct Removed: Codable, Equatable, Sendable {
        public let tool: Tool
        public let configDir: String?

        /// The same folder however it's written: "~/.claude-x" and "/Users/me/.claude-x" match.
        func matches(_ tool: Tool, _ configDir: String?, home: String = userHome()) -> Bool {
            self.tool == tool && Account.resolve(self.configDir, home: home).map(canonical) == Account.resolve(configDir, home: home).map(canonical)
        }
    }

    public var version: Int
    /// The account new sessions of each tool use.
    public var current: [Tool: String]
    public var accounts: [Account]
    public var removed: [Removed]

    public init(current: [Tool: String], accounts: [Account], removed: [Removed] = []) {
        self.version = Registry.currentVersion
        self.current = current
        self.accounts = accounts
        self.removed = removed
    }

    private enum CodingKeys: String, CodingKey { case version, current, accounts, removed }

    /// `removed` came later; registries written before it have none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        current = try c.decode([Tool: String].self, forKey: .current)
        accounts = try c.decode([Account].self, forKey: .accounts)
        removed = try c.decodeIfPresent([Removed].self, forKey: .removed) ?? []
    }

    public static let empty = Registry(current: [:], accounts: [])

    public func account(id: String) -> Account? { accounts.first { $0.id == id } }

    public func accounts(for tool: Tool) -> [Account] { accounts.filter { $0.tool == tool } }

    public var tools: [Tool] { Tool.allCases.filter { t in accounts.contains { $0.tool == t } } }

    public func current(for tool: Tool) -> Account? { current[tool].flatMap(account(id:)) }

    public func isCurrent(_ account: Account) -> Bool { current[account.tool] == account.id }

    /// Display order: grouped by tool, in the user's order within each tool. Positions (1-9 shortcuts) follow it.
    public var ordered: [Account] {
        accounts.enumerated().sorted { l, r in
            l.element.tool != r.element.tool ? l.element.tool < r.element.tool : l.offset < r.offset
        }.map(\.element)
    }

    /// The account whose config the others of its tool share: the one on the default folder, else the first.
    public func primary(for tool: Tool) -> Account? {
        accounts.first { $0.tool == tool && $0.configDir == nil } ?? accounts.first { $0.tool == tool }
    }

    public func validate() throws {
        guard version == Registry.currentVersion else { throw AccError.unsupportedVersion(version) }
        var problems: [String] = []
        var seen = Set<String>()
        for a in accounts {
            if !Registry.isValidID(a.id) {
                problems.append("invalid id '\(a.id)' (use lowercase letters, digits and '-', starting with a letter)")
            } else if Registry.reservedIDs.contains(a.id) {
                problems.append("id '\(a.id)' is reserved for an acc command")
            }
            if !seen.insert(a.id).inserted { problems.append("duplicate id '\(a.id)'") }
            if a.label.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("account '\(a.id)' has an empty label") }
            if let dir = a.configDir, dir.isEmpty { problems.append("account '\(a.id)' has an empty configDir (use null for the default)") }
        }
        for tool in Tool.allCases {
            if accounts.filter({ $0.tool == tool && $0.configDir == nil }).count > 1 {
                problems.append("more than one \(tool.spec.name) account uses the default folder (configDir: null)")
            }
            let folders = accounts.filter { $0.tool == tool }.compactMap(\.configDir)
            for folder in Set(folders) where folders.filter({ $0 == folder }).count > 1 {
                problems.append("more than one \(tool.spec.name) account uses \(folder)")
            }
            let hasAccounts = accounts.contains { $0.tool == tool }
            if let id = current[tool] {
                if account(id: id)?.tool != tool {
                    problems.append("current \(tool.spec.name) account '\(id)' is not a \(tool.spec.name) account in the list")
                }
            } else if hasAccounts {
                problems.append("no current \(tool.spec.name) account")
            }
        }
        if !problems.isEmpty { throw AccError.invalidRegistry(problems) }
    }

    public static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil
    }

    /// Finds an account from what a person types: its position in `ordered` (1-based, as `acc ls`
    /// shows it even when filtered to one tool), its id, or a fragment of its id, label or email
    /// that matches exactly one account (of `tool`, if given).
    public func resolve(_ ref: String, tool: Tool? = nil) throws -> Account {
        let q = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(q) {
            guard ordered.indices.contains(n - 1), tool == nil || ordered[n - 1].tool == tool else { throw AccError.noMatch(ref) }
            return ordered[n - 1]
        }
        let pool = ordered.filter { tool == nil || $0.tool == tool }
        if let exact = pool.first(where: { $0.id == q }) ?? pool.first(where: { $0.label.lowercased() == q }) { return exact }
        let hits = pool.filter { a in
            [a.id, a.label, a.email ?? ""].contains { !q.isEmpty && $0.lowercased().contains(q) }
        }
        switch hits.count {
        case 1: return hits[0]
        case 0: throw AccError.noMatch(ref)
        default: throw AccError.ambiguous(ref, hits.map(\.id))
        }
    }

    /// Whether `configDir` is one of `tool`'s accounts, or was removed from the list.
    public func knows(_ tool: Tool, configDir: String?, home: String = userHome()) -> Bool {
        account(for: tool, configDir: Account.resolve(configDir, home: home), home: home) != nil
            || removed.contains { $0.matches(tool, configDir, home: home) }
    }

    /// The account a running tool belongs to, from the value of its variable (nil or empty = default).
    public func account(for tool: Tool, configDir dir: String?, home: String = userHome()) -> Account? {
        guard let dir, !dir.isEmpty else { return accounts.first { $0.tool == tool && $0.configDir == nil } }
        let target = canonical(dir)
        return accounts.first { a in a.tool == tool && a.resolvedConfigDir(home: home).map(canonical) == target }
    }
}

func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

extension Date {
    /// A file time from `stat`.
    init(_ time: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }
}

/// When the file at `path` was last written, or nil when it can't be read.
func modificationDate(_ path: String) -> Date? {
    var info = stat()
    return stat(path, &info) == 0 ? Date(info.st_mtimespec) : nil
}

/// `path` with the home folder written as "~", for showing to people.
public func abbreviatingHome(_ path: String, home: String = userHome()) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// $HOME, as the tools resolve it, falling back to the account's home directory.
public func userHome() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
    return NSHomeDirectory()
}
