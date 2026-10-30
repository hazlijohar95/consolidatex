import Foundation

/// A conversation transcript in one account's folder.
public struct Session: Equatable, Sendable {
    public let id: String
    public let account: Account
    public let transcript: String
    public let modified: Date
}

/// Moving a conversation to another account of the same tool, so it can continue when
/// the first account runs out. Only tools whose transcripts are plain files support it.
public enum Sessions {
    public static func supports(_ tool: Tool) -> Bool { tool != .opencode }

    /// Every account's conversations started in `cwd`, newest first (optionally only `tool`'s).
    public static func forProject(_ cwd: String, in registry: Registry, tool: Tool? = nil, home: String = userHome()) -> [Session] {
        registry.accounts.filter { (tool == nil || $0.tool == tool) && supports($0.tool) }.flatMap { account -> [Session] in
            switch account.tool {
            case .claude: ClaudeSupport.sessions(in: cwd, account: account, home: home)
            case .codex: CodexSupport.sessions(in: cwd, account: account, home: home)
            case .opencode: []
            }
        }
        .sorted { $0.modified > $1.modified }
    }

    public static func copy(_ session: Session, to account: Account, home: String = userHome()) throws {
        precondition(session.account.tool == account.tool, "sessions only move between accounts of one tool")
        switch account.tool {
        case .claude: try ClaudeSupport.copy(session, to: account, home: home)
        case .codex: try CodexSupport.copy(session, to: account, home: home)
        case .opencode: throw AccError.usage("opencode conversations cannot move between accounts")
        }
    }

    public static func resumeArguments(_ session: Session) -> [String] {
        switch session.account.tool {
        case .claude: ["--resume", session.id]
        case .codex: ["resume", session.id]
        case .opencode: ["--session", session.id]
        }
    }
}
