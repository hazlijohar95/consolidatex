import Foundation

/// Where Claude Code keeps an account's files. The default account is split
/// across ~/.claude (config) and ~/.claude.json (state); every other account
/// keeps both inside its CLAUDE_CONFIG_DIR.
public struct AccountPaths: Equatable, Sendable {
    public let configDir: String
    public let stateFile: String
    public var projects: String { configDir + "/projects" }

    public init(_ account: Account, home: String = userHome()) {
        if let dir = account.resolvedConfigDir(home: home) {
            configDir = dir
            stateFile = dir + "/.claude.json"
        } else {
            configDir = home + "/.claude"
            stateFile = home + "/.claude.json"
        }
    }
}

extension Registry {
    /// The account whose config the others share: the one on Claude Code's default dir, else the first.
    public var primary: Account { accounts.first { $0.configDir == nil } ?? accounts[0] }

    /// The account a running claude belongs to, from its CLAUDE_CONFIG_DIR (nil or empty = default).
    public func account(forConfigDir dir: String?, home: String = userHome()) -> Account? {
        guard let dir, !dir.isEmpty else { return accounts.first { $0.configDir == nil } }
        let target = canonical(dir)
        return accounts.first { a in a.resolvedConfigDir(home: home).map(canonical) == target }
    }
}

func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

/// $HOME, as Claude Code resolves it, falling back to the account's home directory.
public func userHome() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
    return NSHomeDirectory()
}
