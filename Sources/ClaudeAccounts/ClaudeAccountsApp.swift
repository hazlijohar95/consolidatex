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
    let claude = Claude.locateForApp()
    private lazy var usageStore = UsageStore(registryStore: store)
    private var watcher: DispatchSourceFileSystemObject?
    private var usageTimer: Timer?

    init() {
        reload()
        watch()
        // Status lines record usage every few seconds while sessions run; resets also pass with time.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadUsage() }
        }
    }

    var registry: Registry? {
        if case .loaded(let r) = state { return r }
        return nil
    }

    func reload() {
        do {
            state = .loaded(try store.load())
        } catch {
            state = .failed(String(describing: error))
        }
        reloadUsage()
    }

    func reloadUsage() {
        guard let registry else { return }
        let next = usageStore.all(registry)
        if next != usage { usage = next }
    }

    // MARK: Editing. Every change goes through the store, so terminals see it at once.

    private func edit(_ change: (inout Registry) throws -> Void) {
        do {
            state = .loaded(try store.update(change))
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func use(_ account: Account) { edit { $0.current = account.id } }
    func rename(_ account: Account, to label: String) {
        guard label != account.label else { return }
        edit { try $0.rename(account.id, to: label) }
    }
    func remove(_ account: Account) { edit { try $0.remove(account.id) } }
    func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        edit { $0.move(from: from, to: from < destination ? destination - 1 : destination) }
    }

    func useRoomiest() {
        guard let registry, let best = registry.byHeadroom(usage).first else { return }
        use(best)
    }

    /// Registers a new account, shares the primary's config with it, then starts its login.
    func add(label: String, id: String) {
        guard let registry else { return }
        let account = Account(id: id, label: label, configDir: "~/.claude-\(id)")
        do {
            var next = registry
            try next.add(account)
            try FileManager.default.createDirectory(atPath: account.resolvedConfigDir()!, withIntermediateDirectories: true)
            if let claude { _ = try Shared.sync(account, primary: registry.primary, claude: claude, prune: false) }
            try store.save(next)
            state = .loaded(next)
            lastError = nil
            logIn(account)
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Health, sync and login run claude, so they stay off the main thread.

    func checkHealth() {
        guard let registry, !checking else { return }
        checking = true
        let claude = self.claude
        Task.detached {
            var results: [String: AccountHealth] = [:]
            for account in registry.accounts {
                results[account.id] = AccountHealth.check(account, in: registry, claude: claude)
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
        guard let registry, let claude else { lastError = "claude was not found"; return }
        checking = true
        Task.detached {
            var lines: [String] = []
            var failure: String?
            for account in registry.accounts where account.id != registry.primary.id {
                do {
                    let changes = try Shared.sync(account, primary: registry.primary, claude: claude, prune: false)
                    if !changes.isEmpty { lines.append("\(account.label): \(changes.joined(separator: ", "))") }
                } catch {
                    failure = "\(account.label): \(error)"
                }
            }
            let report = lines.isEmpty ? "Everything already matches \(registry.primary.label)." : lines.joined(separator: "\n")
            await MainActor.run {
                self.checking = false
                self.syncReport = report
                self.lastError = failure
                self.checkHealth()
            }
        }
    }

    func dismissSyncReport() { syncReport = nil }

    /// Runs `claude auth login` for the account and watches `auth status` until the browser flow completes.
    func logIn(_ account: Account) {
        guard let claude else { logins[account.id] = .failed("claude was not found"); return }
        logins[account.id] = .waiting
        Task.detached {
            let result = Self.runLogin(account, claude: claude)
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

    nonisolated private static func runLogin(_ account: Account, claude: Claude) -> LoginResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude.executable)
        process.arguments = ["auth", "login"]
        process.environment = Claude.environment(for: account)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(error.localizedDescription) }
        defer { if process.isRunning { process.terminate() } }

        let deadline = Date() + 300
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            if (try? claude.authStatus(for: account))?.loggedIn == true { return .success }
            if !process.isRunning {
                if (try? claude.authStatus(for: account))?.loggedIn == true { return .success }
                let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
                let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
                return .failure(tail.isEmpty ? "login exited without finishing" : tail)
            }
        }
        return .failure("timed out waiting for the browser login")
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
        case .loaded(let registry):
            Text("New claude sessions use:")
            ForEach(Array(registry.accounts.enumerated()), id: \.element.id) { index, account in
                Toggle(isOn: Binding(get: { registry.current == account.id }, set: { _ in model.use(account) })) {
                    Text("\(account.label)    \(UsageFormat.summary(model.usage[account.id]))")
                }
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: []) : nil)
            }
            Divider()
            Button("Use the Account with the Most Room") { model.useRoomiest() }
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
        Button("Manage Accounts…") {
            openWindow(id: "accounts")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { _ in model.toggleOpenAtLogin() }))
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@main
struct ClaudeAccountsApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            AccountMenu(model: model)
        } label: {
            switch model.state {
            case .loaded(let registry):
                let used = model.usage[registry.current].map { " \(Int($0.load(at: Date()).rounded()))%" } ?? ""
                Text("✳︎ \(registry.currentAccount.label)\(used)")
            case .failed: Text("✳︎ ⚠︎")
            }
        }

        Window("Claude Accounts", id: "accounts") {
            AccountsView(model: model)
        }
        .windowResizability(.contentMinSize)
        // `acc ui` opens claude-accounts://manage.
        .handlesExternalEvents(matching: ["manage"])
    }
}
