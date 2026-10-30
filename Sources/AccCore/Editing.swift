import Foundation

/// Changes people make to the account list, shared by the CLI and the app so
/// both enforce the same rules. Each leaves the registry valid or throws.
extension Registry {
    public mutating func add(_ account: Account) throws {
        guard Registry.isValidID(account.id), !Registry.reservedIDs.contains(account.id) else { throw AccError.invalidID(account.id) }
        guard self.account(id: account.id) == nil else { throw AccError.duplicateID(account.id) }
        var next = self
        next.accounts.append(account)
        try next.validate()
        self = next
    }

    public mutating func rename(_ id: String, to label: String) throws {
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { throw AccError.usage("a label cannot be empty") }
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { throw AccError.noMatch(id) }
        accounts[i].label = label
    }

    public mutating func remove(_ id: String) throws {
        guard let account = self.account(id: id) else { throw AccError.noMatch(id) }
        guard id != current else { throw AccError.usage("'\(id)' is the current account; switch to another one first") }
        guard id != primary.id else {
            throw AccError.usage("'\(id)' is the primary account; the others share its config, so it cannot be removed")
        }
        accounts.removeAll { $0.id == account.id }
    }

    /// Moves the account at `from` so it ends up at index `to` (positions drive the 1-9 shortcuts).
    public mutating func move(from: Int, to: Int) {
        guard accounts.indices.contains(from) else { return }
        let account = accounts.remove(at: from)
        accounts.insert(account, at: min(max(to, 0), accounts.count))
    }

    public mutating func recordEmail(_ email: String?, for id: String) {
        if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i].email = email }
    }

    /// An unused, valid id derived from a label: "Hello Team" → "hello-team".
    public func suggestedID(for label: String) -> String {
        var slug = label.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty || !slug.first!.isLetter { slug = "acc" + (slug.isEmpty ? "" : "-" + slug) }
        var candidate = slug, n = 2
        while account(id: candidate) != nil || Registry.reservedIDs.contains(candidate) {
            candidate = "\(slug)-\(n)"
            n += 1
        }
        return candidate
    }
}

/// How one account stands: logged in, and sharing the primary's config.
public struct AccountHealth: Equatable, Sendable {
    public var loggedIn: Bool?
    public var email: String?
    public var problems: [String]
    public var issues: [String]

    public var isHealthy: Bool { loggedIn == true && problems.isEmpty }

    public static func check(_ account: Account, in registry: Registry, claude: Claude?) -> AccountHealth {
        var health = AccountHealth(loggedIn: nil, email: nil, problems: [], issues: [])
        if let dir = account.resolvedConfigDir(), !FileManager.default.fileExists(atPath: dir) {
            health.problems.append("config dir \(dir) does not exist")
            return health
        }
        if let claude {
            do {
                let status = try claude.authStatus(for: account)
                health.loggedIn = status.loggedIn
                health.email = status.email
                if !status.loggedIn { health.problems.append("not logged in") }
            } catch {
                health.problems.append(String(describing: error))
            }
        }
        if account.id != registry.primary.id {
            health.issues = Shared.issues(account, primary: registry.primary)
        }
        return health
    }
}

extension Shared {
    /// What differs between an account and the primary's shared config, in words.
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

    /// Makes one account match the primary's shared config. Returns what it changed.
    public static func sync(_ account: Account, primary: Account, claude: Claude, prune: Bool, home: String = userHome()) throws -> [String] {
        var changes = try link(account, primary: primary, home: home).map { "linked \($0)" }
        let drift = mcpDrift(account, primary: primary, home: home)
        let wanted = mcpServers(primary, home: home)
        for name in drift.missing + drift.different {
            try claude.addMCPServer(name, definition: wanted[name]!, to: account)
            changes.append("MCP \(name) " + (drift.missing.contains(name) ? "added" : "updated"))
        }
        if prune {
            for name in drift.extra {
                try claude.removeMCPServer(name, from: account)
                changes.append("MCP \(name) removed")
            }
        }
        return changes
    }
}

extension Claude {
    /// Finds claude for a GUI app, whose PATH lacks the user's shell additions.
    public static func locateForApp() -> Claude? {
        let env = ProcessInfo.processInfo.environment
        let extra = ["\(userHome())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var augmented = env
        augmented["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        return try? locate(environment: augmented)
    }
}
