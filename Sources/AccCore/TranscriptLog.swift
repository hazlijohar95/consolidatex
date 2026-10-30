import Foundation

/// Where a Claude Code session ran, as its transcript records it: `entrypoint` names the kind of
/// program, and T3 Code's sessions run in its worktrees. A transcript can't tell one terminal from
/// another; the process table can, for sessions running now (`RunningSessions`).
public enum Origin: String, Codable, CaseIterable, Sendable {
    case terminal, t3Code, claudeDesktop, otherApp

    public var name: String {
        switch self {
        case .terminal: "Terminal"
        case .t3Code: "T3 Code"
        case .claudeDesktop: "Claude desktop"
        case .otherApp: "Other apps"
        }
    }

    public static func of(entrypoint: String?, cwd: String?) -> Origin {
        switch entrypoint {
        case "claude-desktop": .claudeDesktop
        case "cli": .terminal
        // T3 Code runs threads in its worktrees and names chats from a t3code-claude-title folder.
        default: (cwd ?? "").contains("/.t3/") || (cwd ?? "").contains("/t3code-claude-title") ? .t3Code : .otherApp
        }
    }
}

/// Recent work on one Claude Code account, from its transcripts (projects/**/*.jsonl, subagents
/// included), which Claude Code appends to on every message and tool result. A file is read in full
/// once, a megabyte at a time, then only for what was appended, so a refresh costs the new lines.
public actor TranscriptLog {
    public struct Activity: Equatable, Sendable {
        public var requests = 0
        /// The newest change to any transcript: when the account last did anything.
        public var lastWrite: Date?
        /// Output tokens by where they were spent.
        public var byOrigin: [Origin: Int] = [:]

        public var outputTokens: Int { byOrigin.values.reduce(0, +) }
    }

    private struct Response {
        let at: Date
        let outputTokens: Int
    }

    /// One transcript is one session, so where it ran is kept once per file.
    private struct FileState {
        var offset: UInt64 = 0
        var origin: Origin?
        var responses: [String: Response] = [:]
    }

    private let projects: URL
    private var files: [URL: FileState] = [:]

    public init(folder: String) {
        projects = URL(fileURLWithPath: folder + "/projects")
    }

    public func activity(at now: Date, over window: TimeInterval = 5 * 3600) -> Activity {
        let cutoff = now - window
        var recent: [URL: FileState] = [:]
        var lastWrite: Date?
        let files = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey])
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "jsonl",
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            lastWrite = max(lastWrite ?? modified, modified)
            guard modified > cutoff else { continue }
            recent[file] = Self.readAppended(file, after: self.files[file] ?? FileState(), cutoff: cutoff)
        }
        self.files = recent
        var activity = Activity(lastWrite: lastWrite)
        activity.requests = spending(after: cutoff, until: .distantFuture) { activity.byOrigin[$0, default: 0] += $1 }
        return activity
    }

    /// Output tokens spent in `(since, until]`, by origin, from what `activity` last read. History
    /// stores these between samples, so a week's shares add up exactly.
    public func tokens(since: Date, until: Date) -> [Origin: Int] {
        var tokens: [Origin: Int] = [:]
        spending(after: since, until: until) { tokens[$0, default: 0] += $1 }
        return tokens
    }

    /// Each reply in the span once, even when a resumed or forked session copied it into another
    /// transcript. Files go in path order, so a copied reply counts toward the same origin every time.
    /// Returns how many replies there were.
    @discardableResult
    private func spending(after since: Date, until: Date, _ add: (Origin, Int) -> Void) -> Int {
        var seen = Set<String>()
        for file in files.keys.sorted(by: { $0.path < $1.path }) {
            guard let state = files[file] else { continue }
            for (key, response) in state.responses where response.at > since && response.at <= until && seen.insert(key).inserted {
                add(state.origin ?? .otherApp, response.outputTokens)
            }
        }
        return seen.count
    }

    /// A file shorter than what was read before has been rewritten, so it's read again from the start.
    private static func readAppended(_ file: URL, after previous: FileState, cutoff: Date) -> FileState {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return previous }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return previous }
        var state = size < previous.offset ? FileState() : previous
        state.responses = state.responses.filter { $0.value.at > cutoff }
        guard size > state.offset, (try? handle.seek(toOffset: state.offset)) != nil else { return state }
        var pending = Data()
        var more = true
        while more {
            // Foundation hands back reads and parses for later release, and a background task never
            // gets around to it, so each chunk drains its own; otherwise a long first read holds all of them.
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { more = false; return }
                // Bytes already searched hold no newline, so a line longer than a chunk is searched once.
                var searchFrom = pending.endIndex
                // Most lines are shorter than a chunk, so usually nothing is left over to copy into.
                if pending.isEmpty {
                    pending = chunk
                    searchFrom = pending.startIndex
                } else {
                    pending.append(chunk)
                }
                var start = pending.startIndex
                // A line still being written has no newline yet; the next read picks it up.
                while let end = pending[searchFrom...].firstIndex(of: newline) {
                    read(pending[start..<end], into: &state)
                    start = pending.index(after: end)
                    searchFrom = start
                }
                state.offset += UInt64(pending.distance(from: pending.startIndex, to: start))
                pending = start == pending.endIndex ? Data() : Data(pending[start...])
            }
        }
        return state
    }

    /// Streaming writes a line per content block and the last carries the final count, so later lines win.
    private static func read(_ line: Data, into state: inout FileState) {
        guard line.range(of: usageKey) != nil, line.range(of: assistantValue) != nil,
              let entry = try? decoder.decode(Entry.self, from: line), entry.type == "assistant",
              let at = Date(iso8601: entry.timestamp)
        else { return }
        if state.origin == nil, let place = try? decoder.decode(Place.self, from: line) {
            state.origin = .of(entrypoint: place.entrypoint, cwd: place.cwd)
        }
        state.responses["\(entry.message.id ?? "")|\(entry.requestId ?? "")"] = Response(at: at, outputTokens: entry.message.usage.output_tokens ?? 0)
    }

    private static let decoder = JSONDecoder()
    private static let newline = UInt8(ascii: "\n")
    /// Checked on the raw bytes first, so only assistant replies pay for a JSON parse.
    private static let usageKey = Data(#""usage""#.utf8)
    private static let assistantValue = Data(#""assistant""#.utf8)

    private struct Entry: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable { let output_tokens: Int? }
            let id: String?
            let usage: Usage
        }
        let type: String
        let timestamp: String
        let requestId: String?
        let message: Message
    }

    /// Read from a file's first reply only.
    private struct Place: Decodable {
        let entrypoint: String?
        let cwd: String?
    }
}
