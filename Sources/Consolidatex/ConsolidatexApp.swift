import AccCore
import AppKit
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

    @Published private(set) var state: State = .failed("loading")
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published var lastError: String?
    @Published private(set) var usage: [String: Usage] = [:]
    @Published private(set) var health: [String: AccountHealth] = [:]
    @Published private(set) var checking = false
    @Published private(set) var logins: [String: Login] = [:]
    @Published private(set) var syncReport: String?

    let store = RegistryStore.standard()
    let runners: [Tool: Runner] = Dictionary(uniqueKeysWithValues: Tool.allCases.compactMap { t in Runner.locateForApp(t).map { (t, $0) } })
    private lazy var usages = Usages(store: UsageStore(registryStore: store))
    private var watcher: DispatchSourceFileSystemObject?
    private var usageTimer: Timer?

    init() {
        reload()
        watch()
        // Usage changes as sessions run and as limits reset, independent of the registry file.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadUsage() }
        }
    }

    var registry: Registry? {
        if case .loaded(let r) = state { return r }
        return nil
    }

    var installedTools: [Tool] { Tool.allCases.filter { runners[$0] != nil } }

    func reload() {
        do {
            state = .loaded(try store.load())
        } catch AccError.registryMissing {
            state = .loaded(.empty)
        } catch {
            state = .failed(String(describing: error))
        }
        reloadUsage()
    }

    func reloadUsage() {
        guard let registry else { return }
        let usages = self.usages
        Task.detached {
            let next = usages.all(registry)
            await MainActor.run { if next != self.usage { self.usage = next } }
        }
    }

    // MARK: Editing. Every change goes through the store, so terminals see it at once.

    private func edit(_ change: (inout Registry) throws -> Void) {
        do {
            var next = registry ?? .empty
            try change(&next)
            try store.save(next)
            state = .loaded(next)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func use(_ account: Account) { edit { try $0.use(account.id) } }
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
        for tool in registry.tools {
            if registry.accounts(for: tool).contains(where: { usage[$0.id] != nil }), let best = registry.byHeadroom(tool, usage).first {
                use(best)
            }
        }
    }

    /// Registers a new account, shares its tool's primary config with it, then starts its login.
    func add(tool: Tool, label: String, id: String) {
        guard let registry else { return }
        let account = registry.newAccount(tool: tool, label: label, id: id)
        do {
            var next = registry
            try next.add(account)
            let runner = runners[tool]
            try runner?.prepare(account)
            if let primary = registry.primary(for: tool) {
                _ = try Shared.sync(account, primary: primary, runner: runner, prune: false)
            }
            try store.save(next)
            state = .loaded(next)
            lastError = nil
            logIn(account)
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Health, sync and login run the tools, so they stay off the main thread.

    func checkHealth() {
        guard let registry, !checking else { return }
        checking = true
        let runners = self.runners
        Task.detached {
            var results: [String: AccountHealth] = [:]
            for account in registry.accounts {
                results[account.id] = AccountHealth.check(account, in: registry, runner: runners[account.tool])
            }
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
            openInTerminal("acc login \(account.id)")
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

    /// Opens Terminal running `command` through a throwaway .command file (no automation permission needed).
    func openInTerminal(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("consolidatex-\(UUID().uuidString).command")
        let script = "#!/bin/zsh -l\n\(command)\necho\nread -k1 '?Press any key to close…'\n"
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

struct AccountMenu: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.state {
        case .loaded(let registry) where registry.accounts.isEmpty:
            Text("No accounts yet")
            Button("Set Up…") { openManager() }
        case .loaded(let registry):
            ForEach(registry.tools, id: \.self) { tool in
                Section(tool.spec.name) {
                    ForEach(registry.accounts(for: tool)) { account in
                        let position = registry.ordered.firstIndex(of: account)! + 1
                        Toggle(isOn: Binding(get: { registry.isCurrent(account) }, set: { _ in model.use(account) })) {
                            Text("\(account.label)    \(UsageFormat.summary(model.usage[account.id], tool: tool))")
                        }
                        .keyboardShortcut(position <= 9 ? KeyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: []) : nil)
                    }
                }
            }
            Divider()
            Button("Use the Accounts with the Most Room") { model.useRoomiest() }
                .keyboardShortcut("a")
        case .failed(let message):
            Text("⚠︎ \(message)")
            Text("Run `acc doctor` in a terminal to fix it.")
        }
        if let error = model.lastError {
            Divider()
            Text("⚠︎ \(error)")
        }
        Divider()
        Button("Manage Accounts…") { openManager() }
            .keyboardShortcut(",")
        Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { _ in model.toggleOpenAtLogin() }))
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openManager() {
        openWindow(id: "accounts")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ConsolidatexApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            AccountMenu(model: model)
        } label: {
            switch model.state {
            case .loaded(let registry):
                // The first tool's current account, which for most people is Claude Code.
                if let account = registry.tools.first.flatMap(registry.current(for:)) {
                    let used = model.usage[account.id].map { " \(Int($0.load(at: Date()).rounded()))%" } ?? ""
                    Text("✳︎ \(account.label)\(used)")
                } else {
                    Text("✳︎")
                }
            case .failed: Text("✳︎ ⚠︎")
            }
        }

        Window("Consolidatex", id: "accounts") {
            AccountsView(model: model)
        }
        .windowResizability(.contentMinSize)
        // `acc ui` opens consolidatex://manage.
        .handlesExternalEvents(matching: ["manage"])
    }
}
