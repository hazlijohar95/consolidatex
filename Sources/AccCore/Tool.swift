import Foundation

/// The coding tools acc can switch accounts for.
public enum Tool: String, Codable, CaseIterable, CodingKeyRepresentable, Comparable, Sendable {
    case claude, codex, opencode

    public static func < (a: Tool, b: Tool) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var spec: ToolSpec {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}

/// Everything acc needs to know to give one tool several accounts. Each account is a
/// folder; launching the tool with `variable` pointing at that folder selects the account.
/// The account on the tool's default folder runs with `variable` unset.
public struct ToolSpec: Sendable {
    public let tool: Tool
    public let name: String
    /// The executable on PATH, and the name of the shell function acc defines for it.
    public let command: String
    public let variable: String
    /// The folder the tool uses when `variable` is unset, relative to home.
    public let defaultDir: String
    /// Folder for accounts acc creates, relative to home, followed by the account id.
    public let newAccountPrefix: String
    /// Added in front of the user's arguments when launching a non-default account.
    public let isolatedArguments: [String]
    public let loginArguments: [String]
    /// True when login asks questions in the terminal, so the app hands it to Terminal.
    public let loginNeedsTerminal: Bool
    public let loginHint: String?
    /// Items in the primary account's folder that every other account symlinks.
    public let sharedItems: [String]

    public static let claude = ToolSpec(
        tool: .claude, name: "Claude Code", command: "claude", variable: "CLAUDE_CONFIG_DIR",
        defaultDir: ".claude", newAccountPrefix: ".claude-", isolatedArguments: [],
        loginArguments: ["auth", "login"], loginNeedsTerminal: false, loginHint: nil,
        sharedItems: ["CLAUDE.md", "settings.json", "skills", "agents", "commands", "plugins", "hooks"])

    // CODEX_HOME holds auth.json, config.toml, sessions and history.
    public static let codex = ToolSpec(
        tool: .codex, name: "Codex", command: "codex", variable: "CODEX_HOME",
        defaultDir: ".codex", newAccountPrefix: ".codex-", isolatedArguments: [],
        loginArguments: ["login"], loginNeedsTerminal: false,
        loginHint: "Codex logs in with whichever ChatGPT account your browser is signed into. Use a private window or sign out of chatgpt.com first to add a different one.",
        sharedItems: ["AGENTS.md", "config.toml", "rules", "skills", "hooks.json", "plugins"])

    // opencode keeps credentials and sessions in $XDG_DATA_HOME/opencode/opencode.db, served by
    // one shared background server; --standalone gives the account its own private server.
    public static let opencode = ToolSpec(
        tool: .opencode, name: "opencode", command: "opencode", variable: "XDG_DATA_HOME",
        defaultDir: ".local/share", newAccountPrefix: ".opencode-", isolatedArguments: ["--standalone"],
        loginArguments: ["auth", "login"], loginNeedsTerminal: true, loginHint: nil,
        sharedItems: [])
}
