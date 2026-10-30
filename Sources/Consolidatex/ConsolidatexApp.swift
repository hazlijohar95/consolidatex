import AccCore
import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    enum State {
        case loaded(Registry)
        case failed(String)
    }

    enum Login: Equatable {
        case waiting
        case inTerminal
        case failed(String)
    }

    @Published private(set) var state: State = .failed("loading") {
        didSet { if let registry { monitor.registry = registry } }
    }
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published var lastError: String?
    @Published private(set) var health: [String: AccountHealth] = [:]
    @Published private(set) var checking = false
    @Published private(set) var logins: [String: Login] = [:]
    @Published private(set) var syncReport: String?
    @Published private(set) var runners: [Tool: Runner] = [:] {
        didSet {
            monitor.runners = runners
            adoptNewAccounts()
        }
    }
    /// Set when someone picks an account while their terminal doesn't follow picks yet.
    @Published private(set) var offerTerminal = false

    let store = RegistryStore.standard()
    let monitor: UsageMonitor
    let shell = ShellInit.Shell.from(path: ProcessInfo.processInfo.environment["SHELL"])
    private var watcher: DispatchSourceFileSystemObject?
    private var forwarding: AnyCancellable?
    private var discovery: Timer?

    init() {
        monitor = UsageMonitor(store: store)
        forwarding = monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        LoginShell.adopt(LoginShell.usualPlaces)
        locateTools()
        Task.detached {
            guard let path = LoginShell.path() else { return }
            await MainActor.run {
                LoginShell.adopt(path)
                self.locateTools()
            }
        }
        reload()
        watch()
        discovery = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptNewAccounts() }
        }
    }

    var registry: Registry? {
        if case .loaded(let r) = state { return r }
        return nil
    }

    var installedTools: [Tool] { Tool.allCases.filter { runners[$0] != nil } }

    private func locateTools() {
        runners = Runner.locateAll()
    }

    func reload() {
        do {
            state = .loaded(try store.loadOrEmpty())
        } catch {
            state = .failed(String(describing: error))
        }
        adoptNewAccounts()
    }

    /// Lists account folders that appear on disk, such as one another app or a manual login created.
    /// Folders `acc rm` took out stay out.
    private func adoptNewAccounts() {
        // Found against what's on disk, so a folder adopted meanwhile isn't adopted twice. Only for
        // installed tools: a folder left behind by an uninstalled one isn't an account in use.
        edit { r in
            for candidate in Discovery.find(excluding: r) where self.runners[candidate.tool] != nil { try r.adopt(candidate) }
        }
    }

    /// The account being worked on now: active lately and not capped; with several, the fullest.
    func accountInUse(at now: Date) -> Account? {
        registry?.accounts
            .filter { monitor.isActive($0, at: now) && monitor.readings[$0.id].map { !$0.isCapped(at: now) } ?? false }
            .max { monitor.readings[$0.id]!.load(at: now) < monitor.readings[$1.id]!.load(at: now) }
    }

    // MARK: Editing. Every change goes through the store, so terminals see it at once.

    private func edit(_ change: (inout Registry) throws -> Void) {
        do {
            // From disk, not `state`: the watcher misses editors that rewrite accounts.json in place.
            let current = try store.loadOrEmpty()
            var next = current
            try change(&next)
            // An unchanged save would wake the file watcher, which reloads and lands back here, and
            // would clear an error the person hasn't read yet.
            guard next != current else {
                state = .loaded(next)
                return
            }
            try store.save(next)
            state = .loaded(next)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func use(_ account: Account) {
        edit { try $0.use(account.id) }
        offerTerminal = lastError == nil && !terminalFollows && !UserDefaults.standard.bool(forKey: "terminalOfferDeclined")
    }

    /// Whether `claude`, `codex` and `opencode` typed in a terminal start on the picked account.
    var terminalFollows: Bool { shell.map { ShellInit.isInstalled($0) } ?? true }

    /// Adds the shell hook and turns on Claude Code's status line: what makes a pick reach the terminal.
    func connectTerminal() {
        guard let shell else { return }
        // The hook runs `acc`, so a terminal without it on PATH would complain on every start.
        guard let acc = Runner.which("acc") else {
            lastError = "acc isn't on your terminal's PATH; install with Homebrew, then try again"
            return
        }
        do {
            try ShellInit.installHook(shell)
            if let primary = registry?.primary(for: .claude) {
                _ = try StatusLineSetup.install(for: primary, acc: acc)
            }
            offerTerminal = false
            lastError = nil
        } catch {
            lastError = "Couldn't connect the terminal: \(error)"
        }
    }

    func declineTerminal() {
        offerTerminal = false
        UserDefaults.standard.set(true, forKey: "terminalOfferDeclined")
    }
    func rename(_ account: Account, to label: String) {
        guard label != account.label else { return }
        edit { try $0.rename(account.id, to: label) }
    }
    func remove(_ account: Account) { edit { try $0.remove(account.id) } }
    func move(_ tool: Tool, from source: IndexSet, to destination: Int) {
        guard let registry, let from = source.first else { return }
        let peers = registry.ordered.filter { $0.tool == tool }
        edit { $0.move(peers[from].id, toToolIndex: from < destination ? destination - 1 : destination) }
    }

    func useRoomiest() {
        guard let registry else { return }
        let usage = monitor.readings
        for tool in registry.tools {
            if registry.accounts(for: tool).contains(where: { usage[$0.id] != nil }), let best = registry.byHeadroom(tool, usage).first {
                use(best)
            }
        }
    }

    /// Registers a new account, shares its tool's primary config with it, then starts its login.
    /// Registered first, so discovery already knows the folder while it fills; sharing runs
    /// `claude mcp add-json` once per server, so it stays off the main thread.
    func add(tool: Tool, label: String, id: String) {
        guard let registry else { return }
        let account = registry.newAccount(tool: tool, label: label, id: id)
        let primary = registry.primary(for: tool)
        let runner = runners[tool]
        edit { try $0.add(account) }
        guard lastError == nil else { return }
        Task.detached {
            do {
                try runner?.prepare(account)
                if let primary { _ = try Shared.sync(account, primary: primary, runner: runner, prune: false) }
                await MainActor.run { self.logIn(account) }
            } catch {
                await MainActor.run { self.lastError = String(describing: error) }
            }
        }
    }

    // MARK: Health, sync and login run the tools, so they stay off the main thread.

    func checkHealth() {
        guard let registry, !checking else { return }
        checking = true
        let runners = self.runners
        Task.detached {
            let results = AccountHealth.checkAll(registry, runners: runners)
            await MainActor.run {
                self.health = results
                self.checking = false
                self.recordEmails(results)
            }
        }
    }

    private func recordEmails(_ results: [String: AccountHealth]) {
        guard let registry else { return }
        let changed = registry.accounts.filter { a in results[a.id]?.email.map { $0 != a.email } ?? false }
        if !changed.isEmpty { edit { r in for a in changed { r.recordEmail(results[a.id]?.email, for: a.id) } } }
    }

    func syncConfig() {
        guard let registry else { return }
        checking = true
        let runners = self.runners
        Task.detached {
            var lines: [String] = []
            var failure: String?
            for account in registry.ordered {
                guard let primary = registry.primary(for: account.tool), primary.id != account.id else { continue }
                do {
                    let changes = try Shared.sync(account, primary: primary, runner: runners[account.tool], prune: false)
                    if !changes.isEmpty { lines.append("\(account.label): \(changes.joined(separator: ", "))") }
                } catch {
                    failure = "\(account.label): \(error)"
                }
            }
            let report = lines.isEmpty ? "Every account already shares its primary's config." : lines.joined(separator: "\n")
            await MainActor.run {
                self.checking = false
                self.syncReport = report
                self.lastError = failure
                self.checkHealth()
            }
        }
    }

    func dismissSyncReport() { syncReport = nil }

    /// Logs an account in: in the app when the tool only needs a browser, otherwise in Terminal.
    func logIn(_ account: Account) {
        guard let runner = runners[account.tool] else {
            logins[account.id] = .failed("\(account.tool.spec.command) is not installed")
            return
        }
        if account.tool.spec.loginNeedsTerminal {
            openInTerminal("\(Self.acc) login \(account.id)")
            logins[account.id] = .inTerminal
            return
        }
        logins[account.id] = .waiting
        Task.detached {
            let result = Self.runLogin(account, runner: runner)
            await MainActor.run {
                switch result {
                case .success: self.logins[account.id] = nil
                case .failure(let message): self.logins[account.id] = .failed(message)
                }
                self.checkHealth()
            }
        }
    }

    enum LoginResult: Sendable { case success, failure(String) }

    /// Runs the tool's login and watches its status until the browser flow completes.
    nonisolated private static func runLogin(_ account: Account, runner: Runner) -> LoginResult {
        try? runner.prepare(account)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runner.executable)
        process.arguments = runner.arguments(for: account, account.tool.spec.loginArguments)
        process.environment = runner.environment(for: account)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(error.localizedDescription) }
        defer { if process.isRunning { process.terminate() } }

        let deadline = Date() + 300
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            if (try? runner.authStatus(for: account))?.loggedIn == true { return .success }
            if !process.isRunning {
                if (try? runner.authStatus(for: account))?.loggedIn == true { return .success }
                let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
                let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
                return .failure(tail.isEmpty ? "login exited without finishing; try acc login \(account.id) in a terminal" : tail)
            }
        }
        return .failure("timed out waiting for the browser login")
    }

    /// The acc bundled next to this app, quoted for the shell, so Terminal doesn't need it on PATH.
    private static let acc = Bundle.main.path(forAuxiliaryExecutable: "acc")
        .map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" } ?? "acc"

    /// Opens Terminal running `command` through a throwaway .command file (no automation permission needed).
    /// An interactive login shell reads .zshrc too, where the tools' PATH entries usually live.
    func openInTerminal(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("consolidatex-\(UUID().uuidString).command")
        let script = "#!/bin/zsh -il\nrm -f -- \"$0\"\n\(command)\necho\nread -k1 '?Press any key to close…'\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            lastError = "could not open Terminal: \(error.localizedDescription)"
        }
    }

    // MARK: App plumbing

    func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            lastError = nil
        } catch {
            lastError = "Open at Login: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func revealRegistry() {
        NSWorkspace.shared.activateFileViewerSelecting([store.file])
    }

    /// The store replaces accounts.json with an atomic rename, which shows up as a
    /// write to the directory, so watch the directory rather than the file.
    private func watch() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let fd = open(store.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

@main
struct ConsolidatexApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Consolidatex", id: "accounts") {
            AccountsView(model: model)
        }
        .windowResizability(.contentMinSize)
        // `acc ui` opens consolidatex://manage.
        .handlesExternalEvents(matching: ["manage"])
    }
}
