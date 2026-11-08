import AccCore
import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class Model: ObservableObject {
    enum State: Equatable {
        case loaded(Registry)
        case failed(String)
    }

    enum Login: Equatable {
        case waiting
        case inTerminal(app: String)
        case failed(String)
    }

    @Published private(set) var state: State = .failed("loading") {
        didSet { if let registry { monitor.registry = registry } }
    }
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// What went wrong last. The next thing the person does replaces it, and closing the panel or
    /// Manage dismisses it.
    @Published private(set) var lastError: String?
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
    /// Where conversations and logins that need a terminal open.
    @Published var terminal = TerminalApp.preferred(saved: UserDefaults.standard.string(forKey: "terminal")) {
        didSet { UserDefaults.standard.set(terminal.id, forKey: "terminal") }
    }
    /// The terminals installed, looked up when the panel opens rather than on every redraw.
    @Published private(set) var terminals = TerminalApp.installed()
    /// When a busy account hits its limit, resume its conversations on the roomiest account without asking.
    @Published var continueAutomatically = UserDefaults.standard.bool(forKey: "continueAutomatically") {
        didSet { UserDefaults.standard.set(continueAutomatically, forKey: "continueAutomatically") }
    }
    /// Move new sessions off an account that hits its limit, and back once it resets.
    @Published var autoSwitch = UserDefaults.standard.object(forKey: "autoSwitch") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch")
            if !autoSwitch { detours = [:] }
        }
    }

    let store = RegistryStore.standard()
    let monitor: UsageMonitor
    let shell = ShellInit.Shell.from(path: ProcessInfo.processInfo.environment["SHELL"])
    private var watcher: DispatchSourceFileSystemObject?
    private var forwarding: AnyCancellable?
    private var discovery: Timer?
    private var hotKeys: [HotKey] = []
    private let switcher = FloatingPanel()
    private let panel = FloatingPanel()
    /// The automatic moves still open, per tool, so each can be undone when its account resets.
    private var detours: [Tool: Detour] = (UserDefaults.standard.data(forKey: "detours")
        .flatMap { try? JSONDecoder().decode([Tool: Detour].self, from: $0) }) ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(detours), forKey: "detours") }
    }

    init() {
        monitor = UsageMonitor(store: store)
        forwarding = monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        Notices.prepare()
        Notices.onContinue = { [weak self] target, conversation in self?.continueConversation(conversation, on: target) }
        monitor.onRefresh = { [weak self] changes, now in self?.follow(changes, at: now) }
        hotKeys = [
            HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in self?.showQuickSwitcher() },
            HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey | shiftKey)) { [weak self] in self?.showPanel() },
        ].compactMap { $0 }
        #if DEBUG
        // For screenshots of the panel without clicking the menu bar.
        if CommandLine.arguments.contains("--show-panel") { DispatchQueue.main.async { [weak self] in self?.showPanel() } }
        #endif
        LoginShell.adopt(LoginShell.usualPlaces)
        locateTools()
        Task {
            guard let path = await LiveUsage.offPool({ LoginShell.path() }) else { return }
            LoginShell.adopt(path)
            self.locateTools()
        }
        reload()
        watch()
        discovery = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Also finds a tool installed while the app runs; a change to `runners` adopts its folders.
                self?.locateTools()
                self?.adoptNewAccounts()
            }
        }
    }

    var registry: Registry? {
        if case .loaded(let r) = state { return r }
        return nil
    }

    var installedTools: [Tool] { Tool.allCases.filter { runners[$0] != nil } }

    private func locateTools() {
        let found = Runner.locateAll()
        // Unchanged nearly every minute, and every assignment redraws the views and runs adoption.
        if found.mapValues(\.executable) != runners.mapValues(\.executable) { runners = found }
    }

    func reload() {
        do {
            setState(.loaded(try store.loadOrEmpty()))
        } catch {
            setState(.failed(String(describing: error)))
        }
        adoptNewAccounts()
    }

    /// The folder watcher and the minute's discovery land here with nothing new most of the time,
    /// and every publish redraws every view of the model.
    private func setState(_ next: State) {
        if next != state { state = next }
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

    /// Applies `change` to accounts.json as it is on disk, not to `state`: the watcher misses editors
    /// that rewrite the file in place. Returns what `change` returns, or nil once `lastError` says why
    /// it failed.
    @discardableResult
    private func edit<T>(_ change: (inout Registry) throws -> T) -> T? {
        do {
            let (result, next) = try store.update { registry in
                let result = try change(&registry)
                return (result, registry)
            }
            setState(.loaded(next))
            return result
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    func dismissError() { lastError = nil }

    func use(_ account: Account) {
        lastError = nil
        guard edit({ try $0.use(account.id) }) != nil else { return }
        // A pick by hand ends any automatic move for that tool.
        detours[account.tool] = nil
        offerTerminal = !terminalFollows && !UserDefaults.standard.bool(forKey: "terminalOfferDeclined")
    }

    func showQuickSwitcher() { switcher.toggle { QuickSwitchView(model: self, close: $0) } }

    /// The menu bar panel, for ⇧⌥⌘A. SwiftUI can't open a menu bar extra from code, so it opens in the
    /// middle of the screen instead.
    func showPanel() {
        panel.toggle(focusFirst: false) { _ in
            UsagePanel(model: self)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        }
    }

    // MARK: Following usage

    /// After each usage refresh: announce resets, move new sessions off capped accounts and back,
    /// and offer to move the conversation of an account that hit its limit while in use.
    private func follow(_ changes: UsageMonitor.LimitChanges, at now: Date) {
        guard let registry else { return }
        let usage = monitor.readings
        let returned = autoSwitch ? switchAroundLimits(usage, at: now) : []
        for id in changes.ready where !returned.contains(id) {
            if let account = registry.account(id: id) { Notices.ready(account, usage[id]) }
        }
        for id in changes.capped {
            guard let account = registry.account(id: id), Sessions.supports(account.tool), monitor.isActive(account, at: now) else { continue }
            let target = registry.roomiest(account.tool, usage, excluding: id, at: now)
            if continueAutomatically, let target {
                continueRunning(account, on: target, at: now)
                continue
            }
            // Finding the conversation reads the account's transcripts, so it stays off the main thread.
            Task.detached {
                let conversation = target == nil ? nil : Sessions.latest(account)
                await MainActor.run { Notices.atLimit(account, continueOn: target, conversation: conversation) }
            }
        }
    }

    /// Applies `Registry.autoPick` to every tool with a choice. Returns the accounts it moved back to.
    private func switchAroundLimits(_ usage: [String: Usage], at now: Date) -> Set<String> {
        guard let registry else { return [] }
        var returned: Set<String> = []
        for tool in registry.tools where registry.accounts(for: tool).count > 1 {
            guard let current = registry.current(for: tool) else { continue }
            // Someone picked by hand since the move, so it's theirs now.
            if let detour = detours[tool], detour.to != current.id { detours[tool] = nil }
            guard let pick = registry.autoPick(tool, usage, detour: detours[tool], at: now) else { continue }
            let returning = detours[tool]?.from == pick.id
            guard edit({ try $0.use(pick.id) }) != nil else { continue }
            detours[tool] = Detour.after(moving: current.id, to: pick.id, existing: detours[tool])
            if returning { returned.insert(pick.id) }
            Notices.switched(from: current, to: pick, returning: returning, until: usage[current.id]?.limitingWindow(at: now)?.resetsAt)
        }
        return returned
    }

    /// Moves `account`'s latest conversation to the account with the most left, and resumes it in the picked terminal.
    func continueElsewhere(_ account: Account) {
        lastError = nil
        guard let registry, let target = registry.roomiest(account.tool, monitor.readings, excluding: account.id) else {
            lastError = "No other \(account.tool.spec.name) account has room right now"
            return
        }
        Task.detached {
            let conversation = Sessions.latest(account)
            await MainActor.run {
                guard let conversation else {
                    self.lastError = "No \(account.tool.spec.name) conversation found on \(account.label)"
                    return
                }
                self.continueConversation(conversation, on: target.id)
            }
        }
    }

    func continueConversation(_ conversation: Sessions.Conversation, on target: String) {
        openInTerminal(Self.continueCommand(conversation, on: target))
    }

    /// `acc continue` for `conversation`, run in the folder it started in.
    private static func continueCommand(_ conversation: Sessions.Conversation, on target: String, prompt: String? = nil) -> String {
        // The id comes from a file another program wrote, so every part is quoted.
        let prompt = prompt.map { " --prompt \(quoted($0))" } ?? ""
        return "cd \(quoted(conversation.folder)) && \(acc) continue \(quoted(target)) --session \(quoted(conversation.id))\(prompt)"
    }

    func refreshTerminals() {
        let installed = TerminalApp.installed()
        if installed != terminals { terminals = installed }
    }

    /// What a moved conversation is told, so it picks the cut-off work back up instead of waiting.
    static let resumePrompt = "The usage limit cut you off, and this conversation has moved to another account. Continue where you left off."

    /// Resumes every conversation still going on `account` on `target`, in windows that open behind the
    /// person's work. One per running session: transcripts written in the last 10 minutes, newest first.
    private func continueRunning(_ account: Account, on target: Account, at now: Date) {
        let sessions = max(1, (monitor.running[account.id] ?? []).reduce(0) { $0 + $1.count })
        let app = terminal
        Task {
            let conversations = await LiveUsage.offPool { Sessions.recent(account, since: now - 10 * 60, limit: sessions) }
            var opened = 0, failure: String?
            for conversation in conversations {
                let command = Self.continueCommand(conversation, on: target.id, prompt: Self.resumePrompt)
                if let problem = await launchInTerminal(command, in: app, activate: false) {
                    failure = problem
                } else {
                    opened += 1
                }
            }
            if let failure { lastError = failure }
            // Said only once the windows opened, so a failed launch never reads as work going on.
            Notices.continued(account, on: target, opened: opened, failure: failure, in: app.name)
        }
    }

    /// The last 7 days per account, from the history the monitor records.
    func weekReports(at now: Date = Date()) -> [WeekReport] {
        (registry?.ordered ?? []).map { account in
            WeekReport(account: account, samples: monitor.history.samples(for: account.id, since: now - WeekReport.span),
                       current: monitor.readings[account.id], at: now)
        }
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
        lastError = nil
        edit { try $0.rename(account.id, to: label) }
    }
    func remove(_ account: Account) {
        lastError = nil
        edit { try $0.remove(account.id) }
    }
    func move(_ tool: Tool, from source: IndexSet, to destination: Int) {
        guard let registry, let from = source.first else { return }
        let peers = registry.ordered.filter { $0.tool == tool }
        lastError = nil
        edit { $0.move(peers[from].id, toToolIndex: from < destination ? destination - 1 : destination) }
    }

    func useRoomiest() {
        for account in registry?.mostLeft(monitor.readings) ?? [] { use(account) }
    }

    /// Registers a new account, shares its tool's primary config with it, then starts its login.
    /// Registered first, so discovery already knows the folder while it fills; sharing runs
    /// `claude mcp add-json` once per server, so it stays off the main thread.
    func add(tool: Tool, label: String, id: String) {
        guard let runner = runners[tool] else {
            lastError = "\(tool.spec.command) is not installed"
            return
        }
        lastError = nil
        guard let account = edit({ try $0.addNew(tool, label: label, id: id) }), let registry else { return }
        Task {
            do {
                _ = try await LiveUsage.offPool { Result { try Shared.setUp(account, in: registry, runner: runner) } }.get()
                self.logIn(account)
            } catch {
                self.lastError = String(describing: error)
            }
        }
    }

    // MARK: Health, sync and login wait on the tools, so the waiting happens on a dispatch thread.

    func checkHealth() {
        guard let registry, !checking else { return }
        checking = true
        let runners = self.runners
        Task {
            let results = await LiveUsage.offPool { AccountHealth.checkAll(registry, runners: runners) }
            self.health = results
            self.checking = false
            self.finishLogins(results)
            self.recordEmails(results)
        }
    }

    /// A login finished in a terminal, or by hand after the app gave up on it: the tool now says the
    /// account is logged in, so its row stops asking and its login is read again.
    private func finishLogins(_ results: [String: AccountHealth]) {
        // A login running in the app reports its own end; a check meanwhile sees the old login.
        for (id, login) in logins where login != .waiting && results[id]?.loggedIn == true {
            logins[id] = nil
            monitor.rereadIdentity(of: id)
        }
    }

    private func recordEmails(_ results: [String: AccountHealth]) {
        guard let registry else { return }
        let changed = registry.accounts.filter { a in results[a.id]?.email.map { $0 != a.email } ?? false }
        guard !changed.isEmpty else { return }
        // Someone else is logged in there now, so the plan and email read before are out of date.
        // Marked first, so the refresh the edit starts reads them.
        for a in changed { monitor.rereadIdentity(of: a.id) }
        edit { r in for a in changed { r.recordEmail(results[a.id]?.email, for: a.id) } }
    }

    func syncConfig() {
        guard let registry else { return }
        checking = true
        let runners = self.runners
        Task {
            var lines: [String] = []
            var failure: String?
            for (account, _, result) in await LiveUsage.offPool({ Shared.syncAll(registry, runners: runners, prune: false) }) {
                do {
                    let changes = try result.get()
                    if !changes.isEmpty { lines.append("\(account.label): \(changes.joined(separator: ", "))") }
                } catch {
                    failure = "\(account.label): \(error)"
                }
            }
            self.checking = false
            self.syncReport = lines.isEmpty ? "Every account already shares its primary's config." : lines.joined(separator: "\n")
            self.lastError = failure
            self.checkHealth()
        }
    }

    func dismissSyncReport() { syncReport = nil }

    /// Logs an account in: in the app when the tool only needs a browser, otherwise in the picked terminal.
    func logIn(_ account: Account) {
        guard let runner = runners[account.tool] else {
            logins[account.id] = .failed("\(account.tool.spec.command) is not installed")
            return
        }
        if account.tool.spec.loginNeedsTerminal {
            openInTerminal("\(Self.acc) login \(Self.quoted(account.id))")
            logins[account.id] = .inTerminal(app: terminal.name)
            return
        }
        logins[account.id] = .waiting
        Task {
            switch await LiveUsage.offPool({ Self.runLogin(account, runner: runner) }) {
            case .success:
                self.logins[account.id] = nil
                self.monitor.rereadIdentity(of: account.id)
            case .failure(let message): self.logins[account.id] = .failed(message)
            }
            self.checkHealth()
        }
    }

    enum LoginResult: Sendable { case success, failure(String) }

    /// Runs the tool's login and watches its status until the browser flow completes.
    nonisolated private static func runLogin(_ account: Account, runner: Runner) -> LoginResult {
        try? runner.prepare(account)
        // Logging in again over a working login: only a changed login, or the command finishing,
        // ends the wait. Otherwise the first poll would see the old login and stop this one.
        let before = try? runner.authStatus(for: account)
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
            if let status = try? runner.authStatus(for: account), status.loggedIn, status != before { return .success }
            if !process.isRunning {
                if (try? runner.authStatus(for: account))?.loggedIn == true { return .success }
                let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
                let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
                return .failure(tail.isEmpty ? "login exited without finishing; try acc login \(account.id) in a terminal" : tail)
            }
        }
        return .failure("timed out waiting for the browser login")
    }

    /// The acc bundled next to this app, quoted for the shell, so the terminal doesn't need it on PATH.
    private static let acc = Bundle.main.path(forAuxiliaryExecutable: "acc").map(quoted) ?? "acc"

    /// `text` as one word for zsh.
    nonisolated static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Runs `command` in a new window of the picked terminal, through a throwaway script that deletes itself.
    /// An interactive login shell reads .zshrc too, where the tools' PATH entries usually live.
    func openInTerminal(_ command: String) {
        let app = terminal
        Task {
            if let failure = await launchInTerminal(command, in: app, activate: true) { lastError = failure }
        }
    }

    /// Writes the script and has `app` run it. Returns what went wrong, if anything.
    private func launchInTerminal(_ command: String, in app: TerminalApp, activate: Bool) async -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("consolidatex-\(UUID().uuidString).command")
        let script = "#!/bin/zsh -il\nrm -f -- \"$0\"\n\(command)\necho\nread -k1 '?Press any key to close…'\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try await app.run(file, activate: activate)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: file)
            return "could not open \(app.name): \(error.localizedDescription)"
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

        Window("Last 7 Days", id: "report") {
            ReportView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}
