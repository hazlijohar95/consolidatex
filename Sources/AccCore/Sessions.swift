import Foundation
#if os(Linux)
import CXattr
#endif

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
    /// A conversation and the folder it ran in: what `acc continue <account> --session <id>` needs, run there.
    public struct Conversation: Equatable, Sendable {
        public let id: String
        public let folder: String

        public init(id: String, folder: String) {
            self.id = id
            self.folder = folder
        }
    }

    public static func supports(_ tool: Tool) -> Bool { tool != .opencode }

    /// The account's most recent conversation, to move elsewhere when the account runs out.
    public static func latest(_ account: Account, home: String = userHome()) -> Conversation? {
        recent(account, since: .distantPast, limit: 1, home: home).first
    }

    /// Up to `limit` of the account's conversations written to since `since`, newest first: the ones
    /// still going when the account ran out.
    public static func recent(_ account: Account, since: Date, limit: Int, home: String = userHome()) -> [Conversation] {
        switch account.tool {
        case .claude: ClaudeSupport.recentConversations(account, home: home, since: since, limit: limit)
        case .codex: CodexSupport.recentConversations(account, home: home, since: since, limit: limit)
        case .opencode: []
        }
    }

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

    /// When a Codex or opencode account last did anything: the newest change to its rollouts or
    /// database. Nil for Claude Code, whose `TranscriptLog` reports it while reading the same files.
    public static func lastActive(_ account: Account, home: String = userHome()) -> Date? {
        let folder = account.folder(home: home)
        let files: [URL] = switch account.tool {
        case .claude: []
        case .codex: CodexSupport.rollouts(home: folder, limit: 5)
        case .opencode: ["opencode.db", "opencode.db-wal"].map { URL(fileURLWithPath: folder + "/opencode/" + $0) }
        }
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    public static func resumeArguments(_ session: Session) -> [String] {
        switch session.account.tool {
        case .claude: ["--resume", session.id]
        case .codex: ["resume", session.id]
        case .opencode: ["--session", session.id]
        }
    }
}

/// Copies items into `directory`, replacing anything already there, and marks every file copied
/// (`CopiedBytes`). Missing sources are skipped.
func copyReplacing(_ items: [URL], into directory: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for item in items where fm.fileExists(atPath: item.path) {
        let destination = directory.appendingPathComponent(item.lastPathComponent)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: item, to: destination)
        for path in [destination.path] + (fm.subpaths(atPath: destination.path) ?? []).map({ destination.path + "/" + $0 }) {
            try CopiedBytes.mark(path)
        }
    }
}

/// A conversation copied into another account's folder holds the first account's work, and the
/// readers of usage and activity would count it as this one's. Each copied file keeps its length at
/// the copy in an extended attribute, and those readers start after it; resuming reads it all.
enum CopiedBytes {
    #if os(Linux)
    /// Linux lets a user set attributes only in the `user.` namespace.
    static let attribute = "user.io.cynco.consolidatex.copied-bytes"
    #else
    static let attribute = "io.cynco.consolidatex.copied-bytes"
    #endif

    /// Records a regular file's length, over any mark it was copied with; folders and links are left alone.
    static func mark(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw failure("read", path) }
        guard info.st_mode & S_IFMT == S_IFREG else { return }
        let value = Array(String(info.st_size).utf8)
        // A volume without extended attributes can't hold the mark; the copy still moves the conversation.
        #if os(Linux)
        let result = lsetxattr(path, attribute, value, value.count, 0)
        #else
        let result = setxattr(path, attribute, value, value.count, 0, XATTR_NOFOLLOW)
        #endif
        guard result == 0 || errno == ENOTSUP else { throw failure("mark", path) }
    }

    /// How many bytes at the start of an open file came with a copy: 0 for a file never copied.
    static func count(in file: Int32) -> UInt64 {
        var value = [UInt8](repeating: 0, count: 20)
        #if os(Linux)
        let length = fgetxattr(file, attribute, &value, value.count)
        #else
        let length = fgetxattr(file, attribute, &value, value.count, 0, 0)
        #endif
        return length > 0 ? UInt64(String(decoding: value.prefix(length), as: UTF8.self)) ?? 0 : 0
    }

    private static func failure(_ action: String, _ path: String) -> AccError {
        .system("cannot \(action) the copy \(path): \(String(cString: strerror(errno)))")
    }
}
