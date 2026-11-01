import Foundation

/// A tool's executable, and how to start it on an account.
public struct Runner: Sendable {
    public struct AuthStatus: Equatable, Sendable {
        public let loggedIn: Bool
        public let email: String?
        /// Extra description where there is no email, such as the providers an opencode account holds.
        public let detail: String?

        public init(loggedIn: Bool, email: String? = nil, detail: String? = nil) {
            self.loggedIn = loggedIn
            self.email = email
            self.detail = detail
        }
    }

    public let tool: Tool
    public let executable: String
    public var spec: ToolSpec { tool.spec }

    public init(tool: Tool, executable: String) {
        self.tool = tool
        self.executable = executable
    }

    /// The first `<command>` on PATH.
    public static func locate(_ tool: Tool, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Runner {
        guard let executable = which(tool.spec.command, environment: environment) else { throw AccError.toolNotFound(tool.spec.command) }
        return Runner(tool: tool, executable: executable)
    }

    /// The installed tools, by tool.
    public static func locateAll(environment: [String: String] = ProcessInfo.processInfo.environment) -> [Tool: Runner] {
        Dictionary(uniqueKeysWithValues: Tool.allCases.compactMap { t in (try? locate(t, environment: environment)).map { (t, $0) } })
    }

    /// The first executable called `name` on PATH.
    public static func which(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }.first(where: FileManager.default.isExecutableFile)
    }

    /// The environment with the tool's variable set for `account`, or removed for its default account.
    public func environment(for account: Account, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env[spec.variable] = account.resolvedConfigDir()
        return env
    }

    public func arguments(for account: Account, _ arguments: [String]) -> [String] {
        (account.configDir == nil ? [] : spec.isolatedArguments) + arguments
    }

    /// Creates the account's folder; some tools (Codex) refuse to start when it is missing.
    public func prepare(_ account: Account) throws {
        if let dir = account.resolvedConfigDir() {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// Replaces this process with the tool running on `account`, or untouched when `account` is nil.
    /// Returns only on failure.
    public func exec(account: Account?, arguments: [String]) -> AccError {
        var args = arguments
        if let account {
            if let dir = account.resolvedConfigDir() {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                setenv(spec.variable, dir, 1)
            } else {
                unsetenv(spec.variable)
            }
            args = self.arguments(for: account, arguments)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) }
        argv.append(nil)
        execv(executable, argv)
        return .system("could not start \(executable): \(String(cString: strerror(errno)))")
    }

    /// Runs the tool on `account` attached to this terminal and waits for it.
    public func run(account: Account, arguments: [String]) throws -> Int32 {
        try prepare(account)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = self.arguments(for: account, arguments)
        process.environment = environment(for: account)
        do { try process.run() } catch { throw AccError.toolFailed(spec.command, error.localizedDescription) }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs the tool on `account` with no terminal, returning its exit status and output
    /// (stdout, plus stderr when `includeErrors`).
    func capture(_ arguments: [String], account: Account, includeErrors: Bool = true) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = self.arguments(for: account, arguments)
        process.environment = environment(for: account)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = includeErrors ? out : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw AccError.toolFailed(spec.command, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    public func authStatus(for account: Account) throws -> AuthStatus {
        switch tool {
        case .claude: try ClaudeSupport.authStatus(self, account)
        case .codex: try CodexSupport.authStatus(self, account)
        case .opencode: try OpencodeSupport.authStatus(self, account)
        }
    }
}
