import Foundation

/// How much of an account's subscription limits are used, as the tool or Anthropic reported it.
public struct Usage: Codable, Equatable, Sendable {
    /// One rate limit: a rolling period such as 5 hours or 7 days, optionally on one model only.
    public struct Window: Codable, Equatable, Sendable {
        public let minutes: Int
        /// The model this limit applies to ("Fable"); nil for the limit all models share.
        public let model: String?
        public let usedPercentage: Double
        /// Nil while the window hasn't started.
        public let resetsAt: Date?

        private enum CodingKeys: String, CodingKey { case minutes, model, usedPercentage, resetsAt, label }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            usedPercentage = try c.decode(Double.self, forKey: .usedPercentage)
            resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
            // Files written before windows carried minutes have only a label: "5h", "7d", "30d".
            minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? Self.minutes(label: c.decode(String.self, forKey: .label))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(minutes, forKey: .minutes)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encode(usedPercentage, forKey: .usedPercentage)
            try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        }

        static func minutes(label: String) -> Int {
            guard let unit = label.last, let n = Int(label.dropLast()) else { return 0 }
            return switch unit { case "d": n * 1440; case "h": n * 60; case "m": n; default: 0 }
        }

        public init(minutes: Int, model: String? = nil, usedPercentage: Double, resetsAt: Date?) {
            self.minutes = minutes
            self.model = model
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        /// "5h", "7d", "7d Fable".
        public var label: String { [Self.label(minutes: minutes), model].compactMap { $0 }.joined(separator: " ") }

        public var duration: TimeInterval { TimeInterval(minutes * 60) }

        /// A window whose reset time has passed has started over.
        public func used(at now: Date) -> Double { resetsAt.map { now >= $0 } ?? false ? 0 : usedPercentage }

        /// When this window fills if use continues at its average rate since it opened. Nil when that
        /// lands near or after the reset, or when the window is too young for its rate to mean much.
        public func projectedCap(readAt: Date, now: Date) -> Date? {
            guard minutes > 0, let resetsAt, resetsAt > now, (10..<100).contains(usedPercentage) else { return nil }
            let elapsed = readAt.timeIntervalSince(resetsAt - duration)
            guard elapsed > duration / 10 else { return nil }
            let cap = readAt + elapsed * (100 - usedPercentage) / usedPercentage
            // A stale reading can project a cap that has already passed; that says nothing about now.
            return cap > now && cap < resetsAt - duration / 20 ? cap : nil
        }

        func limitsSameThing(as other: Window) -> Bool { minutes == other.minutes && model == other.model }

        public static func label(minutes: Int) -> String {
            minutes <= 0 ? "limit" : minutes % 1440 == 0 ? "\(minutes / 1440)d" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
        }
    }

    public struct Forecast: Equatable, Sendable {
        public let window: Window
        public let capsAt: Date
    }

    /// Shortest window first, then the shared limit before per-model ones.
    public let windows: [Window]
    public let recordedAt: Date

    public init(windows: [Window], recordedAt: Date) {
        self.windows = windows.sorted { ($0.minutes, $0.model ?? "") < ($1.minutes, $1.model ?? "") }
        self.recordedAt = recordedAt
    }

    /// The fullest window: what decides whether the account can take more work.
    public func load(at now: Date) -> Double { windows.map { $0.used(at: now) }.max() ?? 0 }

    public func isCapped(at now: Date) -> Bool { load(at: now) >= 100 }

    public func limitingWindow(at now: Date) -> Window? {
        windows.filter { $0.used(at: now) > 0 }.max { $0.usedPercentage < $1.usedPercentage }
    }

    /// The first window this account fills at its current pace. A pace over hours only holds while
    /// someone is working on the account, so windows shorter than a day count only when `active`.
    public func forecast(at now: Date, active: Bool) -> Forecast? {
        guard !isCapped(at: now) else { return nil }
        return windows.filter { active || $0.minutes >= 1440 }
            .compactMap { w in w.projectedCap(readAt: recordedAt, now: now).map { Forecast(window: w, capsAt: $0) } }
            .min { $0.capsAt < $1.capsAt }
    }

    /// This reading plus the windows of `older` it doesn't report and that haven't reset. The status
    /// line reports two windows, Anthropic's usage API also per-model ones, and both feed one store.
    public func merged(over older: Usage?, at now: Date) -> Usage {
        let kept = (older?.windows ?? []).filter { old in
            !windows.contains { $0.limitsSameThing(as: old) } && old.resetsAt.map { $0 > now } ?? false
        }
        return Usage(windows: windows + kept, recordedAt: recordedAt)
    }
}

/// Usage acc recorded itself (Claude Code's status line feeds it), one JSON file per account.
public struct UsageStore: Sendable {
    public let directory: URL

    public init(registryStore: RegistryStore) {
        directory = registryStore.directory.appendingPathComponent("usage", isDirectory: true)
    }

    public func load(_ id: String) -> Usage? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? Self.decoder.decode(Usage.self, from: data)
    }

    /// Folds `reading` into what's stored and returns the result. Claude Code runs the status line on
    /// every update, so an unchanged reading is only rewritten once a minute, to keep its age honest.
    @discardableResult
    public func merge(_ reading: Usage, for id: String, at now: Date = Date()) throws -> Usage {
        try merge(reading, over: load(id), for: id, at: now)
    }

    /// `merge`, for a caller that already has what's stored.
    public func merge(_ reading: Usage, over stored: Usage?, for id: String, at now: Date = Date()) throws -> Usage {
        let next = reading.merged(over: stored, at: now)
        if let stored, stored.windows == next.windows, now.timeIntervalSince(stored.recordedAt) < 60 { return stored }
        try record(next, for: id)
        return next
    }

    private func record(_ usage: Usage, for id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(id).\(getpid()).tmp")
        try Self.encoder.encode(usage).write(to: staging)
        guard rename(staging.path, file(id).path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw AccError.system("cannot write usage for \(id): \(String(cString: strerror(errno)))")
        }
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Last-known usage for any account, from wherever its tool keeps it.
public struct Usages: Sendable {
    public let store: UsageStore

    public init(store: UsageStore) { self.store = store }

    public func usage(for account: Account) -> Usage? {
        switch account.tool {
        case .claude: store.load(account.id)
        // Live reads land in the store; Codex's own session files may be newer.
        case .codex: [store.load(account.id), CodexSupport.latestUsage(home: account.folder())].compactMap { $0 }.max { $0.recordedAt < $1.recordedAt }
        case .opencode: nil
        }
    }

    public func all(_ registry: Registry, tool: Tool? = nil) -> [String: Usage] {
        Dictionary(uniqueKeysWithValues: registry.accounts.filter { tool == nil || $0.tool == tool }.compactMap { a in usage(for: a).map { (a.id, $0) } })
    }
}

extension Registry {
    /// Accounts of `tool` ordered by headroom, most first. Accounts with no known usage rank
    /// as half used: better than a busy account, worse than a known-quiet one.
    public func byHeadroom(_ tool: Tool, _ usage: [String: Usage], at now: Date = Date(), excluding: Set<String> = []) -> [Account] {
        let load = { (a: Account) in usage[a.id]?.load(at: now) ?? 50 }
        return ordered.filter { $0.tool == tool && !excluding.contains($0.id) }.enumerated()
            .sorted { l, r in load(l.element) != load(r.element) ? load(l.element) < load(r.element) : l.offset < r.offset }
            .map(\.element)
    }

    /// The roomiest account of `tool` other than `excluded`, if any is known to have room.
    public func roomiest(_ tool: Tool, _ usage: [String: Usage], excluding excluded: String? = nil, at now: Date = Date()) -> Account? {
        byHeadroom(tool, usage, at: now, excluding: Set([excluded].compactMap { $0 }))
            .first { (usage[$0.id]?.load(at: now) ?? 0) < 90 }
    }
}

public enum UsageFormat {
    /// "5h 82% · 7d 40% · resets in 3h", or a short note when nothing is known.
    public static func summary(_ usage: Usage?, tool: Tool? = nil, at now: Date = Date()) -> String {
        guard let usage else { return empty(tool: tool) }
        var parts = usage.windows.map { "\($0.label) \(Int($0.used(at: now).rounded()))%" }
        if let w = usage.limitingWindow(at: now), w.usedPercentage >= 80, let resetsAt = w.resetsAt {
            parts.append("resets \(relative(resetsAt, from: now))")
        }
        return parts.isEmpty ? "no limits reported" : parts.joined(separator: " · ")
    }

    /// "T3 Code 68% · Terminal 22% · Claude desktop 10%": the largest first, ties in `Origin` order.
    public static func shares(_ tokens: [Origin: Int], limit: Int = .max) -> String? {
        let total = Double(tokens.values.reduce(0, +))
        guard total > 0 else { return nil }
        return Origin.allCases.filter { (tokens[$0] ?? 0) > 0 }
            .sorted { tokens[$0]! > tokens[$1]! }
            .prefix(limit)
            .map { "\($0.name) \(Int((Double(tokens[$0]!) / total * 100).rounded()))%" }
            .joined(separator: " · ")
    }

    /// "1.9M", "12.3K".
    public static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// "Rex ×2, T3 Code".
    public static func running(_ apps: [AppCount]) -> String {
        apps.map { $0.count > 1 ? "\($0.launcher.name) ×\($0.count)" : $0.launcher.name }.joined(separator: ", ")
    }

    /// What to show for an account with no reading: opencode never reports one.
    public static func empty(tool: Tool?) -> String { tool == .opencode ? "no usage data" : "no usage yet" }

    /// "in 3h", "in 25m", "in 2d".
    public static func relative(_ date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s >= 86_400 { return "in \(s / 86_400)d" }
        if s >= 3_600 { return "in \(s / 3_600)h" }
        return "in \(max(1, s / 60))m"
    }
}
