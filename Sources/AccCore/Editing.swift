import Foundation

/// Changes people make to the account list, shared by the CLI and the app so both
/// enforce the same rules. Each leaves the registry valid, or throws and changes nothing.
extension Registry {
    public mutating func add(_ account: Account) throws {
        guard Registry.isValidID(account.id), !Registry.reservedIDs.contains(account.id) else { throw AccError.invalidID(account.id) }
        guard self.account(id: account.id) == nil else { throw AccError.duplicateID(account.id) }
        var next = self
        next.accounts.append(account)
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
}
