import Foundation

/// The parts of the `claude` CLI that acc depends on.
public struct Claude: Sendable {
    public struct AuthStatus: Decodable, Equatable, Sendable {
        public let loggedIn: Bool
        public let email: String?
    }

    public let executable: String

    /// $ACC_CLAUDE, else the first `claude` on PATH.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Claude {
        if let override = environment["ACC_CLAUDE"], !override.isEmpty { return Claude(executable: override) }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return Claude(executable: candidate) }
        }
        throw AccError.claudeNotFound
    }

    public func authStatus(for account: Account) throws -> AuthStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        process.environment = Self.environment(for: account)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw AccError.claudeFailed(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `auth status` exits non-zero when logged out but still prints its JSON.
        guard let status = try? JSONDecoder().decode(AuthStatus.self, from: data) else {
            throw AccError.claudeFailed("`claude auth status` exited \(process.terminationStatus) without readable output")
        }
        return status
    }

    /// The current environment with CLAUDE_CONFIG_DIR set for `account`, or removed for the default account.
    public static func environment(for account: Account, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["CLAUDE_CONFIG_DIR"] = account.resolvedConfigDir()
        return env
    }

    /// Replaces this process with `claude args…` running on `account`. Returns only on failure.
    public func exec(account: Account, arguments: [String]) -> AccError {
        if let dir = account.resolvedConfigDir() {
            setenv("CLAUDE_CONFIG_DIR", dir, 1)
        } else {
            unsetenv("CLAUDE_CONFIG_DIR")
        }
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        execv(executable, argv)
        return .claudeFailed("could not start \(executable): \(String(cString: strerror(errno)))")
    }

    /// Runs `claude args…` on `account` attached to this terminal and waits for it.
    public func run(account: Account, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Self.environment(for: account)
        do { try process.run() } catch { throw AccError.claudeFailed(error.localizedDescription) }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
