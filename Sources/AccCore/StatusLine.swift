import Foundation

/// The JSON Claude Code pipes to a status line command (only the fields acc uses).
public struct StatusInput: Decodable, Sendable {
    public struct Model: Decodable, Sendable { public let display_name: String? }
    public struct Window: Decodable, Sendable {
        public let used_percentage: Double
        public let resets_at: Double
    }
    public struct RateLimits: Decodable, Sendable {
        public let five_hour: Window?
        public let seven_day: Window?
    }
    public struct Context: Decodable, Sendable { public let used_percentage: Double? }

    public let model: Model?
    public let rate_limits: RateLimits?
    public let context_window: Context?

    /// What to render when Claude Code sends nothing readable.
    public static let empty = StatusInput(model: nil, rate_limits: nil, context_window: nil)

    init(model: Model?, rate_limits: RateLimits?, context_window: Context?) {
        self.model = model
        self.rate_limits = rate_limits
        self.context_window = context_window
    }

    public func usage(at now: Date) -> Usage? {
        guard let limits = rate_limits, limits.five_hour != nil || limits.seven_day != nil else { return nil }
        let window = { (w: Window?) in w.map { Usage.Window(usedPercentage: $0.used_percentage, resetsAt: Date(timeIntervalSince1970: $0.resets_at)) } }
        return Usage(fiveHour: window(limits.five_hour), sevenDay: window(limits.seven_day), recordedAt: now)
    }
}

public enum StatusLine {
    /// "✳ CTO · 5h 82% · 7d 40% · Opus 5.5 · ctx 34%", plus a nudge toward the
    /// roomiest other account once this one is nearly out.
    public static func render(account: Account?, usage: Usage?, input: StatusInput, suggestion: Account?, now: Date = Date(), color: Bool = true) -> String {
        func paint(_ s: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
        func percent(_ label: String, _ w: Usage.Window?) -> String? {
            guard let w else { return nil }
            let used = w.used(at: now)
            let code = used >= 90 ? "31" : used >= 70 ? "33" : "32"
            return "\(label) " + paint("\(Int(used.rounded()))%", code)
        }

        var parts = [paint("✳ \(account?.label ?? "unknown account")", "1")]
        if let usage {
            parts += [percent("5h", usage.fiveHour), percent("7d", usage.sevenDay)].compactMap { $0 }
        }
        if let model = input.model?.display_name { parts.append(model) }
        if let ctx = input.context_window?.used_percentage { parts.append("ctx \(Int(ctx.rounded()))%") }

        var line = parts.joined(separator: paint(" · ", "2"))
        if let usage, usage.load(at: now) >= 90, let suggestion {
            line += paint("  ⇢ acc continue \(suggestion.id)", "35")
        }
        return line
    }
}
