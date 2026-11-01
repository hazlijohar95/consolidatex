import Foundation

/// A move the app made on its own, off a capped account, so it can move back once the account
/// the person picked has room again.
public struct Detour: Codable, Equatable, Sendable {
    /// The account the person picked.
    public let from: String
    /// Where new sessions start meanwhile.
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// The detour after the app moves new sessions from `old` to `new`. It keeps pointing back at
    /// the person's pick across several moves, and ends when the move returns there.
    public static func after(moving old: String, to new: String, existing: Detour?) -> Detour? {
        guard let existing, existing.to == old else { return Detour(from: old, to: new) }
        return existing.from == new ? nil : Detour(from: existing.from, to: new)
    }
}

extension Registry {
    /// Where new sessions of `tool` should start when following usage: off a capped current account
    /// onto the one with the most left, and back along `detour` once the picked account has room.
    /// "Room" means under 90% on every window, the same rule as `roomiest`, so a picked account that
    /// reset one window but sits at 98% of another doesn't bounce back and forth.
    /// Nil when the current account should stay.
    public func autoPick(_ tool: Tool, _ usage: [String: Usage], detour: Detour?, at now: Date = Date()) -> Account? {
        guard let current = current(for: tool) else { return nil }
        if usage[current.id]?.isCapped(at: now) == true {
            return roomiest(tool, usage, excluding: current.id, at: now)
        }
        guard let detour, detour.to == current.id, let picked = account(id: detour.from), picked.tool == tool,
              let reading = usage[picked.id], reading.load(at: now) < 90
        else { return nil }
        return picked
    }

    /// What switching to the accounts with the most left picks (`acc auto`, the app's menu): for each
    /// tool with any usage on record, or just `tool`, its account with the most headroom.
    public func mostLeft(_ usage: [String: Usage], tool: Tool? = nil, at now: Date = Date()) -> [Account] {
        tools.filter { t in (tool == nil || t == tool) && accounts(for: t).contains { usage[$0.id] != nil } }
            .compactMap { byHeadroom($0, usage, at: now).first }
    }
}
