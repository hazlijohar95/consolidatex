import Foundation

/// Usage over time, so a week can be looked back on: one JSON line per sample in
/// usage/history/<account id>.jsonl, at most one every `spacing`, kept for `keep`.
public struct UsageHistory: Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let at: Date
        /// The fullest window's share used; 100 means capped.
        public let load: Double
        /// The fullest weekly window's share used, for an account with a weekly limit.
        public let week: Double?

        public init(at: Date, load: Double, week: Double?) {
            self.at = at
            self.load = load
            self.week = week
        }

        public init(_ usage: Usage, at now: Date) {
            self.init(at: now, load: usage.load(at: now), week: usage.windows.filter { $0.minutes >= 10_080 }.map { $0.used(at: now) }.max())
        }
    }

    public static let spacing: TimeInterval = 15 * 60
    public static let keep: TimeInterval = 35 * 86_400
    public let directory: URL

    public init(usageStore: UsageStore) {
        directory = usageStore.directory.appendingPathComponent("history", isDirectory: true)
    }

    public func append(_ sample: Sample, for id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = try Self.encoder.encode(sample) + Data([0x0A])
        guard let handle = try? FileHandle(forWritingTo: file(id)) else { return try line.write(to: file(id)) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func samples(for id: String, since: Date) -> [Sample] {
        guard let text = try? String(contentsOf: file(id), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(Sample.self, from: Data($0.utf8)) }.filter { $0.at >= since }
    }

    /// Drops samples older than `keep`. Rewrites the file, so it runs now and then, not on every append.
    public func prune(_ id: String, at now: Date) throws {
        let kept = try samples(for: id, since: now - Self.keep).map { try Self.encoder.encode($0) + Data([0x0A]) }
        try kept.reduce(Data(), +).write(to: file(id), options: .atomic)
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).jsonl") }

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

/// How one account was used over the last 7 days, from its history and its current reading.
public struct WeekReport: Equatable, Sendable {
    public static let span: TimeInterval = 7 * 86_400

    public let account: Account
    /// The most of its weekly limit it used, for an account with one.
    public let weekUsed: Double?
    /// Hours it spent at a limit.
    public let cappedHours: Double
    /// Hours of the week the history covers. A report on two hours of history says little.
    public let coveredHours: Double

    public init(account: Account, samples: [UsageHistory.Sample], current: Usage?, at now: Date) {
        self.account = account
        let week = samples.filter { $0.at > now - Self.span }.sorted { $0.at < $1.at }
        // A gap longer than two samples means the app wasn't running; it counts as two samples' worth.
        let spans = zip(week, week.dropFirst()).map { ($0.load, min($1.at.timeIntervalSince($0.at), 2 * UsageHistory.spacing)) }
        cappedHours = spans.filter { $0.0 >= 100 }.map(\.1).reduce(0, +) / 3600
        coveredHours = spans.map(\.1).reduce(0, +) / 3600
        let currentWeek = current.flatMap { UsageHistory.Sample($0, at: now).week }
        weekUsed = (week.compactMap(\.week) + [currentWeek].compactMap { $0 }).max()
    }

    /// One thing worth acting on, if anything is.
    public var note: String? {
        if cappedHours >= 1 { return "capped \(Int(cappedHours.rounded()))h this week" }
        if coveredHours >= 72, let weekUsed, weekUsed < 15 { return "mostly idle: \(Int(weekUsed.rounded()))% of its week used" }
        return nil
    }
}
