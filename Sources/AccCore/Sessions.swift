import Foundation

/// A Claude Code conversation transcript in one account's projects dir.
public struct Session: Equatable, Sendable {
    public let id: String
    public let account: Account
    /// <projects>/<project slug>/<id>.jsonl
    public let transcript: String
    public let modified: Date

    public var projectSlug: String { URL(fileURLWithPath: transcript).deletingLastPathComponent().lastPathComponent }
}

public enum Sessions {
    /// Claude Code names a project's folder after its path with every non-alphanumeric character as "-".
    public static func slug(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Every account's transcripts for the project at `cwd`, newest first.
    public static func forProject(_ cwd: String, in registry: Registry, home: String = userHome()) -> [Session] {
        let slug = slug(for: cwd)
        let fm = FileManager.default
        return registry.accounts.flatMap { account -> [Session] in
            let dir = AccountPaths(account, home: home).projects + "/" + slug
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            return names.filter { $0.hasSuffix(".jsonl") }.compactMap { name in
                let path = dir + "/" + name
                guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                return Session(id: String(name.dropLast(6)), account: account, transcript: path, modified: date)
            }
        }
        .sorted { $0.modified > $1.modified }
    }

    /// Copies a session's transcript (and its sidecar folder of subagent transcripts, if any)
    /// into another account so `claude --resume <id>` finds it there.
    public static func copy(_ session: Session, to account: Account, home: String = userHome()) throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: session.transcript)
        let targetDir = URL(fileURLWithPath: AccountPaths(account, home: home).projects).appendingPathComponent(session.projectSlug)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let sidecar = source.deletingPathExtension()
        for item in [source, sidecar] where fm.fileExists(atPath: item.path) {
            let destination = targetDir.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: item, to: destination)
        }
    }
}
