import AppKit
import UniformTypeIdentifiers

/// A terminal the app can hand a command to: continuing a conversation, or a login that needs one.
struct TerminalApp: Identifiable, Hashable {
    enum Launch: Hashable {
        /// Opens a `.command` file and runs it, which needs no automation permission.
        case opensScripts
        /// Rex opens no scripts, but its CLI runs a command in a new window of the running app.
        case rexCLI
    }

    /// The bundle identifier.
    let id: String
    let name: String
    let launch: Launch

    static let terminal = TerminalApp(id: "com.apple.Terminal", name: "Terminal", launch: .opensScripts)

    /// Every terminal the app knows how to drive, in menu order.
    static let known = [
        terminal,
        TerminalApp(id: "com.mitchellh.ghostty", name: "Ghostty", launch: .opensScripts),
        TerminalApp(id: "com.googlecode.iterm2", name: "iTerm", launch: .opensScripts),
        TerminalApp(id: "com.superlogical.rex", name: "Rex", launch: .rexCLI),
    ]

    static func installed() -> [TerminalApp] { known.filter { $0.url != nil } }

    /// The saved pick while it's still installed, else whichever app macOS opens `.command` files with.
    static func preferred(saved: String?) -> TerminalApp {
        let installed = installed()
        let systemDefault = UTType("com.apple.terminal.shell-script")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return installed.first { $0.id == saved } ?? installed.first { $0.id == systemDefault } ?? terminal
    }

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    /// Runs `script`, a zsh script that deletes itself, in a new window. `activate` brings the app
    /// forward; without it the window opens behind whatever the person is typing in.
    func run(_ script: URL, activate: Bool) async throws {
        guard let url else { throw Failure("\(name) isn't installed") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        switch launch {
        case .opensScripts:
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: url, configuration: configuration)
        case .rexCLI:
            // The app first, so the new window has a client to appear in.
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try await Task.detached { try Self.rex(["run", "--shell=none", "--focus=\(activate)", "--", "/bin/zsh", "-il", script.path]) }.value
        }
    }

    /// Runs Rex's CLI, found on the PATH the app took from the login shell.
    private static func rex(_ arguments: [String]) throws {
        let path = (getenv("PATH").map { String(cString: $0) } ?? "").split(separator: ":").map { "\($0)/rex" }
        guard let rex = path.first(where: FileManager.default.isExecutableFile) else {
            throw Failure("couldn't find Rex's rex command on your PATH")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rex)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "rex run failed" : message)
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
