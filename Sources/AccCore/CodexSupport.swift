import Foundation

/// Codex specifics. Everything lives under CODEX_HOME: auth.json, and
/// sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl transcripts whose token_count
/// events carry the account's rate limits.
public enum CodexSupport {
    static func authStatus(_ runner: Runner, _ account: Account) throws -> Runner.AuthStatus {
        // `codex login status` reports on stderr and exits 0 only when logged in.
        let (code, _) = try runner.capture(["login", "status"], account: account)
        let identity = identity(home: account.folder())
        return Runner.AuthStatus(loggedIn: code == 0, email: identity?.email, detail: identity?.plan)
    }

    /// Email and plan from the id_token claims in auth.json (absent when Codex keeps the login in the keychain).
    static func identity(home: String) -> Identity? {
        guard let data = FileManager.default.contents(atPath: home + "/auth.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String
        else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let claims = decodeBase64URL(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: claims) as? [String: Any]
        else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return Identity(email: payload["email"] as? String, plan: (auth?["chatgpt_plan_type"] as? String)?.capitalized)
    }

    static func decodeBase64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }

    /// Rollout files, newest first, without reading them.
    static func rollouts(home: String, limit: Int) -> [URL] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: home + "/sessions")
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var found: [URL] = []
        for year in children(root) {
            for month in children(year) {
                for day in children(month) {
                    found += children(day).filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
                    if found.count >= limit { return Array(found.prefix(limit)) }
                }
            }
        }
        return found
    }

    /// The most recent rate limits Codex recorded for this account. A rollout last written before
    /// `after` holds nothing newer than that, so it isn't read.
    public static func latestUsage(home: String, after: Date? = nil, scanning limit: Int = 25) -> Usage? {
        for file in rollouts(home: home, limit: limit) where after.map({ (modificationDate(file.path) ?? .distantPast) > $0 }) ?? true {
            if let usage = lastTokenCount(in: file, bytes: 256 * 1024) { return usage }
        }
        return nil
    }

    /// The newest token_count event in the last `bytes` of a rollout. The app reads this every 15
    /// seconds, so lines are found on the raw bytes and only those naming token_count become text.
    static func lastTokenCount(in file: URL, bytes: Int) -> Usage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        return tail.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Usage? in
            let key: StaticString = #""token_count""#
            var lines: [Range<Int>] = []
            var from = 0
            while from < buffer.count, let hit = memmem(buffer.baseAddress! + from, buffer.count - from, key.utf8Start, key.utf8CodeUnitCount) {
                let at = buffer.baseAddress!.distance(to: hit)
                let lineStart = buffer[..<at].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                let lineEnd = buffer[at...].firstIndex(of: 0x0A) ?? buffer.count
                // The first line of a tail that starts mid-file is cut off.
                if lineStart > 0 || start == 0 { lines.append(lineStart..<lineEnd) }
                from = lineEnd
            }
            return lines.reversed().lazy.compactMap { parseTokenCount(String(decoding: buffer[$0], as: UTF8.self)) }.first
        }
    }

    /// A token_count event line → Usage. Only the main "codex" limit counts toward the subscription.
    public static func parseTokenCount(_ line: String) -> Usage? {
        struct Window: Decodable { let used_percent: Double; let window_minutes: Int?; let resets_at: Double? }
        struct Limits: Decodable { let limit_id: String?; let plan_type: String?; let primary: Window?; let secondary: Window? }
        struct Payload: Decodable { let type: String; let rate_limits: Limits? }
        struct Event: Decodable { let timestamp: String?; let payload: Payload }
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)),
              event.payload.type == "token_count", let limits = event.payload.rate_limits
        else { return nil }
        let window = { (w: Window?) in w.map { RateWindow(usedPercent: $0.used_percent, minutes: $0.window_minutes, resetsAt: $0.resets_at) } }
        return usage(limitID: limits.limit_id, plan: limits.plan_type, primary: window(limits.primary), secondary: window(limits.secondary),
                     at: event.timestamp.flatMap { try? Date.iso8601.parse($0) } ?? Date())
    }

    /// One rate-limit window as Codex reports it, in a session file or from its app server.
    struct RateWindow {
        let usedPercent: Double
        let minutes: Int?
        let resetsAt: Double?
    }

    /// Codex's limits for the subscription. Other limit ids are per-model extras; the subscription's
    /// is "codex", or unnamed on older versions. Without a duration, the first window is 5 hours on
    /// paid plans and a month on Free and Go. A window without a reset time is left out: an old
    /// reading of it could never be seen to reset, and would hold the account at its percentage.
    static func usage(limitID: String?, plan: String?, primary: RateWindow?, secondary: RateWindow?, at: Date) -> Usage? {
        guard limitID == nil || limitID == "codex" else { return nil }
        let monthly = plan == "free" || plan == "go"
        let windows = [(primary, monthly ? 43_200 : 300), (secondary, 10_080)].compactMap { window, fallback -> Usage.Window? in
            guard let window, let resetsAt = window.resetsAt else { return nil }
            return Usage.Window(minutes: window.minutes ?? fallback, usedPercentage: window.usedPercent,
                                resetsAt: Date(timeIntervalSince1970: resetsAt))
        }
        return windows.isEmpty ? nil : Usage(windows: windows, recordedAt: at)
    }

    /// Codex sessions started in `cwd`, read from the session_meta line at the top of each rollout.
    static func sessions(in cwd: String, account: Account, home: String, scanning limit: Int = 300) -> [Session] {
        let target = canonical(cwd)
        return rollouts(home: account.folder(home: home), limit: limit).compactMap { file in
            guard let meta = conversation(in: file), canonical(meta.folder) == target,
                  let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            else { return nil }
            return Session(id: meta.id, account: account, transcript: file.path, modified: date)
        }
    }

    /// The rollout written most recently. Names sort by start time, so a long session started
    /// yesterday can still be the live one; the newest ten by name are compared by write time.
    static func latestConversation(_ account: Account, home: String) -> Sessions.Conversation? {
        let modified = { (url: URL) in modificationDate(url.path) ?? .distantPast }
        return rollouts(home: account.folder(home: home), limit: 10).max { modified($0) < modified($1) }.flatMap(conversation(in:))
    }

    /// The conversation id and folder from the session_meta line at the top of a rollout.
    static func conversation(in file: URL) -> Sessions.Conversation? {
        struct Meta: Decodable { let id: String?; let cwd: String? }
        struct Head: Decodable { let type: String; let payload: Meta }
        guard let first = firstLine(of: file),
              let head = try? JSONDecoder().decode(Head.self, from: Data(first.utf8)),
              head.type == "session_meta", let folder = head.payload.cwd,
              let id = head.payload.id ?? sessionID(fromFileName: file.lastPathComponent)
        else { return nil }
        return Sessions.Conversation(id: id, folder: folder)
    }

    /// rollout-2026-10-30T10-00-00-<uuid>[_<uuid>].jsonl → <uuid>
    static func sessionID(fromFileName name: String) -> String? {
        let pattern = #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-fA-F-]{36})"#
        guard let match = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[match].suffix(36))
    }

    /// Copies the rollout to the same sessions/YYYY/MM/DD folder of `account`, where `codex resume <id>` scans.
    static func copy(_ session: Session, to account: Account, home: String) throws {
        let source = URL(fileURLWithPath: session.transcript)
        let day = source.deletingLastPathComponent()
        let relative = [day.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                        day.deletingLastPathComponent().lastPathComponent, day.lastPathComponent].joined(separator: "/")
        try copyReplacing([source], into: URL(fileURLWithPath: account.folder(home: home) + "/sessions/" + relative))
    }

    /// The complete lines in the first `bytes` of a file.
    static func headLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: bytes)) ?? Data()
        var lines = String(decoding: chunk, as: UTF8.self).split(separator: "\n").map(String.init)
        if chunk.count == bytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return String(decoding: chunk, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    static func tailLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

