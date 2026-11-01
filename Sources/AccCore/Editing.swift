import Foundation

/// Changes people make to the account list, shared by the CLI and the app so both
/// enforce the same rules. Each leaves the registry valid, or throws and changes nothing.
extension Registry {
    public mutating func add(_ account: Account) throws {
        guard Registry.isValidID(account.id), !Registry.reservedIDs.contains(account.id) else { throw AccError.invalidID(account.id) }
        guard self.account(id: account.id) == nil else { throw AccError.duplicateID(account.id) }
        var next = self
        next.accounts.append(account)
        next.removed.removeAll { $0.matches(account.tool, account.configDir) }
        if next.current[account.tool] == nil { next.current[account.tool] = account.id }
        try next.validate()
        self = next
    }

    public mutating func use(_ id: String) throws {
        guard let account = account(id: id) else { throw AccError.noMatch(id) }
        current[account.tool] = id
    }

    public mutating func rename(_ id: String, to label: String) throws {
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { throw AccError.usage("a label cannot be empty") }
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { throw AccError.noMatch(id) }
        accounts[i].label = label
    }

    public mutating func remove(_ id: String) throws {
        guard let account = account(id: id) else { throw AccError.noMatch(id) }
        let others = accounts(for: account.tool).filter { $0.id != id }
        if isCurrent(account), !others.isEmpty {
            throw AccError.usage("'\(id)' is the current \(account.tool.spec.name) account; switch to another one first")
        }
        if primary(for: account.tool)?.id == id, !others.isEmpty {
            throw AccError.usage("'\(id)' is the primary \(account.tool.spec.name) account; the others share its config, so remove them first")
        }
        accounts.removeAll { $0.id == id }
        if others.isEmpty { current[account.tool] = nil }
        if !removed.contains(where: { $0.matches(account.tool, account.configDir) }) {
            removed.append(Removed(tool: account.tool, configDir: account.configDir))
        }
    }

    /// Adds an account found on disk, labelled as discovery found it and with the email its tool cached.
    @discardableResult
    public mutating func adopt(_ found: Discovery.Candidate, home: String = userHome()) throws -> Account {
        var account = newAccount(tool: found.tool, label: found.label)
        account.configDir = found.configDir
        account.email = Identity.read(account, home: home)?.email
        try add(account)
        return account
    }

    /// Moves an account to `index` among the accounts of its own tool (positions drive the 1-9 shortcuts).
    public mutating func move(_ id: String, toToolIndex index: Int) {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts.remove(at: from)
        let peers = accounts.indices.filter { accounts[$0].tool == account.tool }
        let target = index < peers.count ? peers[max(index, 0)] : (peers.last.map { $0 + 1 } ?? accounts.count)
        accounts.insert(account, at: target)
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

    /// A new account of `tool` in its own folder under home.
    public func newAccount(tool: Tool, label: String, id: String? = nil) -> Account {
        let id = id ?? suggestedID(for: label)
        return Account(id: id, tool: tool, label: label, configDir: "~/" + tool.spec.newAccountPrefix + id)
    }

    /// The first step of adding an account, before `Shared.setUp` and its login: listing it first
    /// means discovery knows its folder while the login fills it, and a failed login leaves an
    /// account to log in again rather than a stray folder. Labelled "<Tool> <n>" unless `label`
    /// is given, in its own folder unless `configDir` names one.
    @discardableResult
    public mutating func addNew(_ tool: Tool, label: String? = nil, id: String? = nil, configDir: String? = nil) throws -> Account {
        var account = newAccount(tool: tool, label: label ?? "\(tool.spec.name) \(accounts(for: tool).count + 1)", id: id)
        if let configDir { account.configDir = configDir }
        try add(account)
        return account
    }
}
