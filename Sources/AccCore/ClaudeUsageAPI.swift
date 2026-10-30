import CryptoKit
import Foundation

/// Anthropic's endpoint behind Claude Code's /usage, read with each account's own Claude Code login.
/// Unlike the status line it covers idle accounts and per-model weekly limits. It is undocumented, and
/// answers each account only every few minutes, so callers pace themselves with `LiveUsage.Schedule`.
enum ClaudeUsageAPI {
    typealias Outcome = LiveUsage.Outcome

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(_ account: Account, home: String = userHome()) async -> Outcome {
        guard let login = await LiveUsage.offPool({ login(for: account, home: home) }) else { return .failed("Not logged in") }
        if let expiresAt = login.expiresAt, expiresAt / 1000 < Date().timeIntervalSince1970 {
            return .failed("Login expired; one message on this account refreshes it")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The endpoint serves Claude Code; this is the client string it is known to accept.
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return .failed("Usage API unreachable")
        }
        switch http.statusCode {
        case 200: return parse(data, at: Date()).map(Outcome.reading) ?? .failed("Usage API sent a reply acc can't read")
        case 429: return .retryAfter(http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? LiveUsage.spacing)
        default: return .failed("Usage API returned HTTP \(http.statusCode)")
        }
    }

    /// `{"limits": [{"group": "session", "percent": 12, "resets_at": "…", "scope": {"model": {"display_name": "Fable"}}}]}`.
    /// The session group is the 5-hour window; every other group is weekly.
    static func parse(_ data: Data, at now: Date) -> Usage? {
        struct Body: Decodable {
            struct Limit: Decodable {
                struct Scope: Decodable {
                    struct Model: Decodable { let display_name: String? }
                    let model: Model?
                }
                let group: String?
                let percent: Double?
                let resets_at: String?
                let scope: Scope?
            }
            let limits: [Limit]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), let limits = body.limits else { return nil }
        return Usage(windows: limits.map { l in
            Usage.Window(minutes: l.group == "session" ? 300 : 10_080, model: l.scope?.model?.display_name,
                         usedPercentage: l.percent ?? 0, resetsAt: l.resets_at.flatMap(Date.init(iso8601:)))
        }, recordedAt: now)
    }

    struct Login: Decodable {
        let accessToken: String
        /// Milliseconds since 1970.
        let expiresAt: Double?
    }

    /// Through /usr/bin/security, so a keychain prompt, if any, names a system tool rather than acc.
    static func login(for account: Account, home: String) -> Login? {
        struct Item: Decodable { let claudeAiOauth: Login }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService(for: account, home: home), "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONDecoder().decode(Item.self, from: data))?.claudeAiOauth
    }

    /// Claude Code names a login's keychain item after a hash of CLAUDE_CONFIG_DIR; the default login's has no suffix.
    static func keychainService(for account: Account, home: String) -> String {
        guard let dir = account.resolvedConfigDir(home: home) else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }
}

extension Date {
    /// ISO 8601 with any number of fractional digits, which are dropped. Transcripts have one
    /// timestamp per line, so this uses the format style, which parses 200 times faster than
    /// ISO8601DateFormatter.
    init?(iso8601 string: String) {
        guard let date = try? Self.iso8601.parse(string) else { return nil }
        self.init(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
