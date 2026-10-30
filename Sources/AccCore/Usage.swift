import Foundation

/// How much of an account's subscription limits are used, as the tool itself reported it.
public struct Usage: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// "5h", "7d", "30d".
        public let label: String
        public let usedPercentage: Double
        public let resetsAt: Date

        public init(label: String, usedPercentage: Double, resetsAt: Date) {
            self.label = label
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        /// A window whose reset time has passed has started over.
        public func used(at now: Date) -> Double { now >= resetsAt ? 0 : usedPercentage }

        public static func label(minutes: Int) -> String {
            minutes % 1440 == 0 ? "\(minutes / 1440)d" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
        }
    }

    public let windows: [Window]
    public let recordedAt: Date

    public init(windows: [Window], recordedAt: Date) {
        self.windows = windows
        self.recordedAt = recordedAt
    }

    /// The fullest window: what decides whether the account can take more work.
    public func load(at now: Date) -> Double { windows.map { $0.used(at: now) }.max() ?? 0 }

    public func limitingWindow(at now: Date) -> Window? {
        windows.filter { $0.used(at: now) > 0 }.max { $0.usedPercentage < $1.usedPercentage }
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

    public func record(_ usage: Usage, for id: String) throws {
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
        case .codex: CodexSupport.latestUsage(home: account.folder())
        case .opencode: nil
        }
    }

    public func all(_ registry: Registry) -> [String: Usage] {
        Dictionary(uniqueKeysWithValues: registry.accounts.compactMap { a in usage(for: a).map { (a.id, $0) } })
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
        guard let usage else { return tool == .opencode ? "no usage data" : "no data yet" }
        var parts = usage.windows.map { "\($0.label) \(Int($0.used(at: now).rounded()))%" }
        if let w = usage.limitingWindow(at: now), w.usedPercentage >= 80 {
            parts.append("resets \(relative(w.resetsAt, from: now))")
        }
        return parts.isEmpty ? "no limits reported" : parts.joined(separator: " · ")
    }

    /// "in 3h", "in 25m", "in 2d".
    public static func relative(_ date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s >= 86_400 { return "in \(s / 86_400)d" }
        if s >= 3_600 { return "in \(s / 3_600)h" }
        return "in \(max(1, s / 60))m"
    }
}
