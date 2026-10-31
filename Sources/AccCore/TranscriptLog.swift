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

    private let projects: String
    private var files: [String: FileState] = [:]
    /// The newest change to any transcript the last walk found, or to a known one since.
    private var lastWrite: Date?
    private var walkedAt = Date.distantPast

    public init(folder: String) {
        projects = folder + "/projects"
    }

    /// Finding new transcripts opens every folder under projects/, so it happens once a minute, or
    /// when `complete` asks; in between only the transcripts already known are checked.
    public func activity(at now: Date, over window: TimeInterval = 5 * 3600, complete: Bool = false) -> Activity {
        let cutoff = now - window
        var recent: [String: FileState] = [:]
        func found(_ modified: Date, _ path: () -> String) {
            lastWrite = max(lastWrite ?? modified, modified)
            guard modified > cutoff else { return }
            let file = path()
            recent[file] = Self.readAppended(file, after: files[file] ?? FileState(), cutoff: cutoff)
        }
        if complete || now.timeIntervalSince(walkedAt) >= 60 {
            walkedAt = now
            lastWrite = nil
            Self.transcripts(in: projects, found)
        } else {
            for file in files.keys { if let modified = modificationDate(file) { found(modified) { file } } }
        }
        files = recent
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
        for file in files.keys.sorted() {
            guard let state = files[file] else { continue }
            for (key, response) in state.responses where response.at > since && response.at <= until && seen.insert(key).inserted {
                add(state.origin ?? .otherApp, response.outputTokens)
            }
        }
        return seen.count
    }

    /// Calls `visit` with the modification time of every .jsonl file under `directory`, and a way to
    /// get its path. The walk covers thousands of files, so it reads names straight from the
    /// directory, stats only transcripts, and makes a path only for a file that asks for it.
    static func transcripts(in directory: String, _ visit: (Date, () -> String) -> Void) {
        guard let dir = opendir(directory) else { return }
        defer { closedir(dir) }
        var folders: [String] = []
        while let entry = readdir(dir) {
            withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { cName in
                    let name = UnsafeRawBufferPointer(start: cName, count: Int(entry.pointee.d_namlen))
                    let path = { directory + "/" + String(decoding: name, as: UTF8.self) }
                    let isTranscript = name.count > jsonl.count && name.suffix(jsonl.count).elementsEqual(jsonl)
                    var type = Int32(entry.pointee.d_type)
                    var info = stat()
                    // Some file systems don't say what an entry is. A link to a folder is never followed.
                    if type == DT_UNKNOWN {
                        guard fstatat(dirfd(dir), cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                        type = info.st_mode & S_IFMT == S_IFDIR ? DT_DIR : DT_REG
                    }
                    if type == DT_DIR {
                        if !name.elementsEqual(dot), !name.elementsEqual(dotDot) { folders.append(path()) }
                    } else if isTranscript, fstatat(dirfd(dir), cName, &info, 0) == 0 {
                        visit(Date(info.st_mtimespec), path)
                    }
                }
            }
        }
        for folder in folders { transcripts(in: folder, visit) }
    }

    private static let dot = Array(".".utf8), dotDot = Array("..".utf8), jsonl = Array(".jsonl".utf8)

    /// A file shorter than what was read before has been rewritten, so it's read again from the start.
    private static func readAppended(_ path: String, after previous: FileState, cutoff: Date) -> FileState {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return previous }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { return previous }
        let size = UInt64(info.st_size)
        var state = size < previous.offset ? FileState() : previous
        state.responses = state.responses.filter { $0.value.at > cutoff }
        guard size > state.offset else { return state }
        // Read a megabyte at a time into one buffer; a line longer than the buffer doubles it.
        var buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(min(size - state.offset, 1 << 20)), alignment: 1)
        defer { buffer.deallocate() }
        // The bytes before `filled` start a line that the last read didn't finish.
        var filled = 0
        // Stops at the size read above, so a file that keeps growing can't hold the read open.
        while state.offset + UInt64(filled) < size {
            if filled == buffer.count {
                let larger = UnsafeMutableRawBufferPointer.allocate(byteCount: buffer.count * 2, alignment: 1)
                larger.copyMemory(from: UnsafeRawBufferPointer(buffer))
                buffer.deallocate()
                buffer = larger
            }
            let base = buffer.baseAddress!
            let count = pread(file, base + filled, buffer.count - filled, off_t(state.offset) + off_t(filled))
            guard count > 0 else { break }
            let end = filled + count
            var start = 0, searchFrom = filled
            // On older systems JSONDecoder parses through Foundation objects that wait for release, and a
            // background task never drains them, so each read drains its own; otherwise a first read holds all of them.
            autoreleasepool {
                while let newline = memchr(base + searchFrom, Int32(UInt8(ascii: "\n")), end - searchFrom) {
                    let lineEnd = base.distance(to: newline)
                    read(UnsafeRawBufferPointer(rebasing: buffer[start..<lineEnd]), into: &state, cutoff: cutoff)
                    start = lineEnd + 1
                    searchFrom = start
                }
            }
            state.offset += UInt64(start)
            // A line still being written has no newline yet; the next refresh reads it.
            filled = end - start
            if start > 0 { memmove(base, base + start, filled) }
        }
        return state
    }

    /// Streaming writes a line per content block and the last carries the final count, so later lines win.
    private static func read(_ line: UnsafeRawBufferPointer, into state: inout FileState, cutoff: Date) {
        guard contains(line, usageKey), contains(line, assistantValue) else { return }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!), count: line.count, deallocator: .none)
        guard let entry = try? decoder.decode(Entry.self, from: data), entry.type == "assistant",
              let at = Date(iso8601: entry.timestamp), at > cutoff
        else { return }
        if state.origin == nil, let place = try? decoder.decode(Place.self, from: data) {
            state.origin = .of(entrypoint: place.entrypoint, cwd: place.cwd)
        }
        state.responses["\(entry.message.id ?? "")|\(entry.requestId ?? "")"] = Response(at: at, outputTokens: entry.message.usage.output_tokens ?? 0)
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ text: StaticString) -> Bool {
        memmem(line.baseAddress, line.count, text.utf8Start, text.utf8CodeUnitCount) != nil
    }

    private static let decoder = JSONDecoder()
    /// Checked on the raw bytes first, so only assistant replies pay for a JSON parse.
    private static let usageKey: StaticString = #""usage""#
    private static let assistantValue: StaticString = #""assistant""#

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
