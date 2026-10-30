import Foundation

/// Claude Code specifics: login status, user-scope MCP servers (kept in each account's own
/// state file), the status line payload, and session transcripts.
public enum ClaudeSupport {
    /// ~/.claude.json for the default account, <dir>/.claude.json otherwise.
    public static func stateFile(_ account: Account, home: String = userHome()) -> String {
        account.resolvedConfigDir(home: home).map { $0 + "/.claude.json" } ?? home + "/.claude.json"
    }

    static func authStatus(_ runner: Runner, _ account: Account) throws -> Runner.AuthStatus {
        struct Status: Decodable { let loggedIn: Bool; let email: String? }
        let (code, output) = try runner.capture(["auth", "status"], account: account, includeErrors: false)
        // `auth status` exits non-zero when logged out but still prints its JSON.
        guard let s = try? JSONDecoder().decode(Status.self, from: output) else {
            throw AccError.toolFailed("claude", "`claude auth status` exited \(code) without readable output")
        }
        return Runner.AuthStatus(loggedIn: s.loggedIn, email: s.email)
    }

    public static func mcpServers(_ account: Account, home: String = userHome()) -> [String: NSDictionary] {
        guard let data = FileManager.default.contents(atPath: stateFile(account, home: home)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [:] }
        return servers.compactMapValues { $0 as? NSDictionary }
    }

    /// Adds or replaces a user-scope MCP server, through claude itself so its own file locking applies.
    public static func addMCPServer(_ runner: Runner, _ name: String, definition: NSDictionary, to account: Account) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys]), as: UTF8.self)
        if mcpServers(account)[name] != nil { try removeMCPServer(runner, name, from: account) }
        let (code, output) = try runner.capture(["mcp", "add-json", "--scope", "user", name, json], account: account)
        guard code == 0 else { throw AccError.toolFailed("claude", "mcp add-json \(name) exited \(code): \(String(decoding: output, as: UTF8.self))") }
    }

    public static func removeMCPServer(_ runner: Runner, _ name: String, from account: Account) throws {
        let (code, output) = try runner.capture(["mcp", "remove", "--scope", "user", name], account: account)
        guard code == 0 else { throw AccError.toolFailed("claude", "mcp remove \(name) exited \(code): \(String(decoding: output, as: UTF8.self))") }
    }

    /// Claude Code names a project's folder after its path with every non-alphanumeric character as "-".
    public static func projectSlug(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func sessions(in cwd: String, account: Account, home: String) -> [Session] {
        let dir = account.folder(home: home) + "/projects/" + projectSlug(for: cwd)
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.compactMap { name in
            let path = dir + "/" + name
            guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
            return Session(id: String(name.dropLast(6)), account: account, transcript: path, modified: date)
        }
    }

    /// Copies the transcript and its sidecar folder (subagent transcripts) into the same project folder of `account`.
    static func copy(_ session: Session, to account: Account, home: String) throws {
        let source = URL(fileURLWithPath: session.transcript)
        let targetDir = URL(fileURLWithPath: account.folder(home: home) + "/projects").appendingPathComponent(source.deletingLastPathComponent().lastPathComponent)
        try copyReplacing([source, source.deletingPathExtension()], into: targetDir)
    }
}

/// The JSON Claude Code pipes to a status line command (only the fields acc uses).
public struct StatusInput: Decodable, Sendable {
    public struct Model: Decodable, Sendable { public let display_name: String? }
    public struct Window: Decodable, Sendable {
        public let used_percentage: Double
        public let resets_at: Double
    }
    public struct RateLimits: Decodable, Sendable {
        public let five_hour: Window?
        public let seven_day: Window?
    }
    public struct Context: Decodable, Sendable { public let used_percentage: Double? }

    public let model: Model?
    public let rate_limits: RateLimits?
    public let context_window: Context?

    /// What to render when Claude Code sends nothing readable.
    public static let empty = StatusInput(model: nil, rate_limits: nil, context_window: nil)

    init(model: Model?, rate_limits: RateLimits?, context_window: Context?) {
        self.model = model
        self.rate_limits = rate_limits
        self.context_window = context_window
    }

    public func usage(at now: Date) -> Usage? {
        guard let limits = rate_limits else { return nil }
        let windows = [("5h", limits.five_hour), ("7d", limits.seven_day)].compactMap { label, w in
            w.map { Usage.Window(label: label, usedPercentage: $0.used_percentage, resetsAt: Date(timeIntervalSince1970: $0.resets_at)) }
        }
        return windows.isEmpty ? nil : Usage(windows: windows, recordedAt: now)
    }
}

public enum StatusLine {
    /// "✳ CTO · 5h 82% · 7d 40% · Opus 5.5 · ctx 34%", plus a nudge toward the
    /// roomiest other account once this one is nearly out.
    public static func render(account: Account?, usage: Usage?, input: StatusInput, suggestion: Account?, now: Date = Date(), color: Bool = true) -> String {
        func paint(_ s: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        var parts = [paint("✳ \(account?.label ?? "unknown account")", "1")]
        for w in usage?.windows ?? [] {
            let used = w.used(at: now)
            parts.append("\(w.label) " + paint("\(Int(used.rounded()))%", used >= 90 ? "31" : used >= 70 ? "33" : "32"))
        }
        if let model = input.model?.display_name { parts.append(model) }
        if let ctx = input.context_window?.used_percentage { parts.append("ctx \(Int(ctx.rounded()))%") }
        var line = parts.joined(separator: paint(" · ", "2"))
        if let usage, usage.load(at: now) >= 90, let suggestion {
            line += paint("  ⇢ acc continue \(suggestion.id)", "35")
        }
        return line
    }
}

/// Copies items into `directory`, replacing anything already there; missing sources are skipped.
func copyReplacing(_ items: [URL], into directory: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for item in items where fm.fileExists(atPath: item.path) {
        let destination = directory.appendingPathComponent(item.lastPathComponent)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: item, to: destination)
    }
}
