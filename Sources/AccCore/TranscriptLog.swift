import Foundation

/// Recent work on one Claude Code account, from its transcripts (projects/**/*.jsonl, subagents
/// included), which Claude Code appends to on every message and tool result. A file is read in full
/// once, then only for what was appended, so a refresh costs the new lines.
public actor TranscriptLog {
    public struct Activity: Equatable, Sendable {
        public var outputTokens = 0
        public var requests = 0
        /// The newest change to any transcript: when the account last did anything.
        public var lastWrite: Date?
    }

    private struct Response {
        let at: Date
        let outputTokens: Int
    }

    private struct FileState {
        var offset: UInt64 = 0
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
        let responses = recent.values.reduce(into: [String: Int]()) { all, file in
            for (key, response) in file.responses where response.at > cutoff { all[key] = response.outputTokens }
        }
        return Activity(outputTokens: responses.values.reduce(0, +), requests: responses.count, lastWrite: lastWrite)
    }

    /// A file shorter than what was read before has been rewritten, so it's read again from the start.
    private static func readAppended(_ file: URL, after previous: FileState, cutoff: Date) -> FileState {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return previous }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return previous }
        var state = size < previous.offset ? FileState() : previous
        state.responses = state.responses.filter { $0.value.at > cutoff }
        guard size > state.offset,
              (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.readToEnd(),
              // A line still being written has no newline yet; the next read picks it up.
              let end = data.lastIndex(of: newline)
        else { return state }

        // Streaming writes a line per content block and the last carries the final count, so later lines win.
        for line in data[..<end].split(separator: newline) where line.range(of: usageKey) != nil && line.range(of: assistantValue) != nil {
            guard let entry = try? decoder.decode(Entry.self, from: line), entry.type == "assistant",
                  let at = Date(iso8601: entry.timestamp)
            else { continue }
            state.responses["\(entry.message.id ?? "")|\(entry.requestId ?? "")"] = Response(at: at, outputTokens: entry.message.usage.output_tokens ?? 0)
        }
        state.offset += UInt64(data.distance(from: data.startIndex, to: end) + 1)
        return state
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
}
