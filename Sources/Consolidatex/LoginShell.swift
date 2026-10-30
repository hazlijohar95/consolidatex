import AccCore
import Foundation

/// The PATH a terminal has. An app starts with launchd's bare PATH, so tools installed through
/// Homebrew, nvm, pnpm or mise stay invisible until it asks the login shell, as T3 Code and VS Code do.
enum LoginShell {
    /// Places tools commonly live, for the moments before the shell answers or if it never does.
    static let usualPlaces = ["~/.local/bin", "~/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        .map { $0.replacingOccurrences(of: "~", with: userHome()) }

    /// Puts `front` ahead of this process's PATH, so every tool the app starts, and the tools those
    /// start (an npm-installed `claude` needs `node`), see what the terminal sees.
    static func adopt(_ front: [String]) {
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        setenv("PATH", (front + current).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":"), 1)
    }

    /// The login shell's PATH, else launchd's. Shells with heavy rc files can take seconds, so it waits up to 10.
    static func path() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("consolidatex-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        // Written to a file rather than read from a pipe: a background job started by the user's rc
        // files can hold a pipe open long after the shell exits. The temp path has no quotes in it.
        if run(shell, ["-ilc", "printenv PATH > '\(file.path)'"], timeout: 10),
           let path = try? String(contentsOf: file, encoding: .utf8), let dirs = split(path) {
            return dirs
        }
        let out = Pipe()
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["getenv", "PATH"]
        launchctl.standardOutput = out
        guard (try? launchctl.run()) != nil else { return nil }
        launchctl.waitUntilExit()
        return split(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private static func split(_ path: String) -> [String]? {
        let dirs = path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        return dirs.isEmpty ? nil : dirs
    }

    /// True when the command exited by itself within `timeout`. Its status doesn't matter: rc files
    /// often end on a failing line after PATH is already set.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return false }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return false
        }
        return true
    }
}
