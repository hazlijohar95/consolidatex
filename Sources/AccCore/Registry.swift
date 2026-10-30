import Foundation

/// One Claude Code subscription. `configDir == nil` means Claude Code's default
/// (~/.claude with ~/.claude.json), which must run with CLAUDE_CONFIG_DIR unset:
/// pointing CLAUDE_CONFIG_DIR at ~/.claude selects a different config file and keychain entry.
public struct Account: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var configDir: String?
    public var email: String?

    public init(id: String, label: String, configDir: String?, email: String? = nil) {
        self.id = id
        self.label = label
        self.configDir = configDir
        self.email = email
    }

    /// The value for CLAUDE_CONFIG_DIR, or nil to leave it unset.
    public func resolvedConfigDir(home: String = NSHomeDirectory()) -> String? {
        guard let configDir else { return nil }
        if configDir == "~" { return home }
        if configDir.hasPrefix("~/") { return home + configDir.dropFirst(1) }
        return configDir
    }
}

public struct Registry: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Words `acc` treats as subcommands, so they can never be account ids.
    public static let reservedIDs: Set<String> = [
        "add", "current", "dir", "doctor", "help", "login", "ls", "list", "rename", "rm", "run", "use", "version",
    ]

    public var version: Int
    public var current: String
    public var accounts: [Account]

    public init(current: String, accounts: [Account]) {
        self.version = Registry.currentVersion
        self.current = current
        self.accounts = accounts
    }

    public var currentAccount: Account {
        // validate() guarantees `current` names an account.
        accounts.first { $0.id == current }!
    }

    public func account(id: String) -> Account? { accounts.first { $0.id == id } }

    public func validate() throws {
        guard version == Registry.currentVersion else { throw AccError.unsupportedVersion(version) }
        var problems: [String] = []
        if accounts.isEmpty { problems.append("no accounts") }
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
        if accounts.filter({ $0.configDir == nil }).count > 1 {
            problems.append("more than one account uses the default config dir (configDir: null)")
        }
        if !accounts.contains(where: { $0.id == current }) {
            problems.append("current account '\(current)' is not in the list")
        }
        if !problems.isEmpty { throw AccError.invalidRegistry(problems) }
    }

    public static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil
    }

    /// Finds an account from what a person types: its 1-based position, its id,
    /// or a fragment of its id, label or email that matches exactly one account.
    public func resolve(_ ref: String) throws -> Account {
        let q = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(q) {
            guard accounts.indices.contains(n - 1) else { throw AccError.noMatch(ref) }
            return accounts[n - 1]
        }
        if let exact = accounts.first(where: { $0.id == q || $0.label.lowercased() == q }) { return exact }
        let hits = accounts.filter { a in
            [a.id, a.label, a.email ?? ""].contains { !q.isEmpty && $0.lowercased().contains(q) }
        }
        switch hits.count {
        case 1: return hits[0]
        case 0: throw AccError.noMatch(ref)
        default: throw AccError.ambiguous(ref, hits.map(\.id))
        }
    }
}
