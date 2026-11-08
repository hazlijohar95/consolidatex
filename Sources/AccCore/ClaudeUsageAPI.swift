#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic's endpoint behind Claude Code's /usage, read with each account's own Claude Code login.
/// Unlike the status line it covers idle accounts and per-model weekly limits. It is undocumented, and
/// answers each account only every few minutes, so callers pace themselves with `LiveUsage.Schedule`.
enum ClaudeUsageAPI {
    typealias Outcome = LiveUsage.Outcome

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(_ account: Account, home: String = userHome()) async -> Outcome {
        await fetch(with: LiveUsage.offPool { login(for: account, home: home) }, at: Date())
    }

    static func fetch(with login: Login?, at now: Date) async -> Outcome {
        guard let login else { return .failed("Not logged in") }
        // A token that runs out during the request would come back as a 401, so one about to expire counts as expired.
        if let expiresAt = login.expiresAt, expiresAt / 1000 < now.timeIntervalSince1970 + 60 {
            return .tokenExpired
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
        case 200: return parse(data, at: now).map(Outcome.reading) ?? .failed("Usage API sent a reply acc can't read")
        case 401: return .failed("Anthropic rejected this login; log in again")
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

    /// What Claude Code stores for a login, in the keychain or in its credentials file.
    private struct Stored: Decodable { let claudeAiOauth: Login }

    /// From the keychain on macOS. Where there is none, or Claude Code couldn't use it, Claude Code
    /// keeps the login in `.credentials.json` in its config folder.
    static func login(for account: Account, home: String) -> Login? {
        #if os(macOS)
        if let login = keychainLogin(for: account, home: home) { return login }
        #endif
        let file = URL(fileURLWithPath: account.folder(home: home) + "/.credentials.json")
        return (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: file)))?.claudeAiOauth
    }

    #if os(macOS)
    /// Through /usr/bin/security, so a keychain prompt, if any, names a system tool rather than acc.
    private static func keychainLogin(for account: Account, home: String) -> Login? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService(for: account, home: home), "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.start()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard process.waitForExit() == 0 else { return nil }
        return (try? JSONDecoder().decode(Stored.self, from: data))?.claudeAiOauth
    }

    /// Claude Code names a login's keychain item after a hash of CLAUDE_CONFIG_DIR; the default login's has no suffix.
    static func keychainService(for account: Account, home: String) -> String {
        guard let dir = account.resolvedConfigDir(home: home) else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }
    #endif
}

extension Date {
    /// ISO 8601 with any number of fractional digits, none included, which are dropped. Transcripts
    /// have one timestamp per line, so this uses the format style, which parses 200 times faster
    /// than ISO8601DateFormatter. A time without a fraction is also tried without one, so it parses
    /// however strictly the system's style treats a missing fraction.
    init?(iso8601 string: String) {
        guard let date = (try? Self.iso8601.parse(string)) ?? (try? Self.iso8601Seconds.parse(string)) else { return nil }
        self.init(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// ISO 8601 with fractional seconds, kept.
    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso8601Seconds = Date.ISO8601FormatStyle()
}
