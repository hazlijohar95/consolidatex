import Foundation

/// Subscription usage as Claude Code reports it to the status line
/// (`rate_limits.five_hour` / `seven_day`), recorded per account.
public struct Usage: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let usedPercentage: Double
        public let resetsAt: Date

        public init(usedPercentage: Double, resetsAt: Date) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        /// A window whose reset time has passed has started over.
        public func used(at now: Date) -> Double { now >= resetsAt ? 0 : usedPercentage }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    public let recordedAt: Date

    public init(fiveHour: Window?, sevenDay: Window?, recordedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.recordedAt = recordedAt
    }

    /// The tighter of the two windows: what decides whether the account can take more work.
    public func load(at now: Date) -> Double {
        max(fiveHour?.used(at: now) ?? 0, sevenDay?.used(at: now) ?? 0)
    }

    /// The window that is limiting right now, for "resets in" hints.
    public func limitingWindow(at now: Date) -> Window? {
        [fiveHour, sevenDay].compactMap { $0 }.filter { $0.used(at: now) > 0 }.max { $0.usedPercentage < $1.usedPercentage }
    }
}

/// Last-known usage per account, one small JSON file each under <acc home>/usage.
public struct UsageStore: Sendable {
    public let directory: URL

    public init(registryStore: RegistryStore) {
        directory = registryStore.directory.appendingPathComponent("usage", isDirectory: true)
    }

    public func load(_ id: String) -> Usage? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? Self.decoder.decode(Usage.self, from: data)
    }

    public func all(_ registry: Registry) -> [String: Usage] {
        Dictionary(uniqueKeysWithValues: registry.accounts.compactMap { a in load(a.id).map { (a.id, $0) } })
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

extension Registry {
    /// Accounts ordered by headroom, most first. Accounts with no recorded usage
    /// rank as half used: better than a busy account, worse than a known-quiet one.
    public func byHeadroom(_ usage: [String: Usage], at now: Date = Date(), excluding: Set<String> = []) -> [Account] {
        let load = { (a: Account) in usage[a.id]?.load(at: now) ?? 50 }
        return accounts.filter { !excluding.contains($0.id) }.enumerated()
            .sorted { l, r in load(l.element) != load(r.element) ? load(l.element) < load(r.element) : l.offset < r.offset }
            .map(\.element)
    }
}

public enum UsageFormat {
    /// "5h 82% · 7d 40%", or "no data" when nothing has been recorded.
    public static func summary(_ usage: Usage?, at now: Date = Date()) -> String {
        guard let usage else { return "no data yet" }
        var parts: [String] = []
        if let w = usage.fiveHour { parts.append("5h \(Int(w.used(at: now).rounded()))%") }
        if let w = usage.sevenDay { parts.append("7d \(Int(w.used(at: now).rounded()))%") }
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
