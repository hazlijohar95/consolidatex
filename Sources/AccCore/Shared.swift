import Foundation

/// Config every account shares with the primary account: files and folders are
/// symlinked into each account's config dir, and user-scope MCP servers (which
/// live in each account's own state file) are mirrored from the primary.
public enum Shared {
    public static let items = ["CLAUDE.md", "settings.json", "skills", "agents", "commands", "plugins", "hooks"]

    public enum Link: Equatable, Sendable {
        case linked
        case missing
        /// A real file or folder is in the way; acc never replaces those.
        case local
        case elsewhere(String)
    }

    public static func links(for account: Account, primary: Account, home: String = userHome()) -> [(item: String, state: Link)] {
        let source = AccountPaths(primary, home: home).configDir
        let target = AccountPaths(account, home: home).configDir
        guard source != target else { return [] }
        let fm = FileManager.default
        return items.compactMap { item in
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
        let source = AccountPaths(primary, home: home).configDir
        let target = AccountPaths(account, home: home).configDir
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        return try links(for: account, primary: primary, home: home).filter { $0.state == .missing }.map { item, _ in
            try FileManager.default.createSymbolicLink(atPath: target + "/" + item, withDestinationPath: source + "/" + item)
            return item
        }
    }

    /// User-scope MCP server definitions, by name, as stored in the account's state file.
    public static func mcpServers(_ account: Account, home: String = userHome()) -> [String: NSDictionary] {
        let path = AccountPaths(account, home: home).stateFile
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [:] }
        return servers.compactMapValues { $0 as? NSDictionary }
    }

    public struct MCPDrift: Equatable, Sendable {
        public var missing: [String] = []
        public var extra: [String] = []
        public var different: [String] = []
        public var isEmpty: Bool { missing.isEmpty && extra.isEmpty && different.isEmpty }
    }

    public static func mcpDrift(_ account: Account, primary: Account, home: String = userHome()) -> MCPDrift {
        let want = mcpServers(primary, home: home)
        let have = mcpServers(account, home: home)
        var drift = MCPDrift()
        drift.missing = want.keys.filter { have[$0] == nil }.sorted()
        drift.extra = have.keys.filter { want[$0] == nil }.sorted()
        drift.different = want.keys.filter { name in have[name].map { !$0.isEqual(want[name]!) } ?? false }.sorted()
        return drift
    }
}
