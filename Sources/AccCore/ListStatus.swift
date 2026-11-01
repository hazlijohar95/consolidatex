import Foundation

/// The JSON shape `acc ls --json` emits: the registry's existing fields plus per-account
/// usage, running sessions, and a roomiest pick per tool.
///
/// `build` is the only constructor. main.swift encodes it; no business logic lives there.
public struct ListStatus: Sendable {
    public let version: Int
    /// The account each tool's next session starts on, by tool raw value.
    public let current: [Tool: String]
    public let accounts: [AccountStatus]
    public let removed: [Registry.Removed]
    /// The roomiest account id for each tool, or null when every account is at 90 % or more.
    public let roomiest: [Tool: String?]

    public static func build(
        registry: Registry,
        usages: [String: Usage],
        running: [String: [RunningSession]],
        tool: Tool? = nil,
        now: Date = Date()
    ) -> ListStatus {
        // Rank per tool: 1 = most headroom.
        var rank: [String: Int] = [:]
        for t in Tool.allCases {
            for (i, a) in registry.byHeadroom(t, usages, at: now).enumerated() {
                rank[a.id] = i + 1
            }
        }

        let shown = tool.map { t in registry.ordered.filter { $0.tool == t } } ?? registry.ordered
        let accounts = shown.map { a in
            AccountStatus(
                id: a.id,
                tool: a.tool,
                label: a.label,
                configDir: a.configDir,
                email: a.email,
                configDirPath: a.folder(),
                current: registry.isCurrent(a),
                rank: rank[a.id] ?? 1,
                usage: usages[a.id].map { UsageStatus(from: $0, at: now) },
                running: RunningSessions.byApp(running[a.id] ?? [])
                    .map { RunningEntry(app: $0.launcher.name, count: $0.count) }
            )
        }

        let tools = tool.map { [$0] } ?? registry.tools
        let roomiest = Dictionary(uniqueKeysWithValues: tools.map { t in
            (t, registry.roomiest(t, usages, at: now)?.id)
        })

        return ListStatus(
            version: registry.version,
            current: registry.current,
            accounts: accounts,
            removed: registry.removed,
            roomiest: roomiest
        )
    }
}

/// Per-account data for `acc ls --json`: all registry fields plus usage, running sessions,
/// the resolved config folder path, whether it is current, and its rank by headroom.
public struct AccountStatus: Codable, Sendable {
    public let id: String
    public let tool: Tool
    public let label: String
    public let configDir: String?
    public let email: String?
    /// Resolved absolute path of the account's config folder.
    public let configDirPath: String
    /// True when new sessions of this tool start on this account.
    public let current: Bool
    /// Position in the headroom order for this tool: 1 = most headroom.
    public let rank: Int
    public let usage: UsageStatus?
    public let running: [RunningEntry]
}

/// The last known usage reading for one account, computed as of the time `build` ran.
public struct UsageStatus: Codable, Sendable {
    /// Fullest shared-window percentage (`Usage.load`). Per-model limits don't affect this.
    public let load: Double
    public let capped: Bool
    public let recordedAt: Date
    public let windows: [WindowStatus]

    init(from usage: Usage, at now: Date) {
        load = usage.load(at: now)
        capped = usage.isCapped(at: now)
        recordedAt = usage.recordedAt
        windows = usage.windows.map { WindowStatus(from: $0, at: now) }
    }
}

/// One rate-limit window, as of the time `build` ran.
public struct WindowStatus: Codable, Sendable {
    /// Human label, e.g. "5h", "7d", "7d Fable".
    public let label: String
    public let minutes: Int
    /// Nil for a limit all models share; named for a per-model limit.
    public let model: String?
    /// Percentage used right now: 0 when the reset time has passed.
    public let used: Double
    public let resetsAt: Date?
    /// When this window was last read; nil when read together with `recordedAt`.
    public let readAt: Date?

    init(from window: Usage.Window, at now: Date) {
        label = window.label
        minutes = window.minutes
        model = window.model
        used = window.used(at: now)
        resetsAt = window.resetsAt
        readAt = window.readAt
    }
}

/// One app running sessions on an account right now.
public struct RunningEntry: Codable, Sendable {
    public let app: String
    public let count: Int
}

// MARK: - Codable

/// Custom encoding keeps the existing top-level key set and writes null roomiest values
/// explicitly rather than omitting them, so consumers can distinguish "no accounts" from
/// "all accounts capped".
extension ListStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, current, accounts, removed, roomiest
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(current, forKey: .current)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(removed, forKey: .removed)
        var rm = c.nestedContainer(keyedBy: RawCodingKey.self, forKey: .roomiest)
        for tool in Tool.allCases where roomiest.keys.contains(tool) {
            try rm.encode(roomiest[tool]!, forKey: RawCodingKey(tool.rawValue))
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        current = try c.decode([Tool: String].self, forKey: .current)
        accounts = try c.decode([AccountStatus].self, forKey: .accounts)
        removed = try c.decodeIfPresent([Registry.Removed].self, forKey: .removed) ?? []
        let rm = try c.nestedContainer(keyedBy: RawCodingKey.self, forKey: .roomiest)
        roomiest = Dictionary(uniqueKeysWithValues: rm.allKeys.compactMap { key in
            Tool(rawValue: key.stringValue).map { ($0, try? rm.decodeIfPresent(String.self, forKey: key)) }
        })
    }
}

private struct RawCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue s: String) { stringValue = s }
    init?(intValue: Int) { nil }
}
