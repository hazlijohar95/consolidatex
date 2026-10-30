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

    @Published private(set) var state: State = .failed("loading")
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?

    let store = RegistryStore.standard()
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        reload()
        watch()
    }

    func reload() {
        do {
            state = .loaded(try store.load())
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func use(_ account: Account) {
        do {
            state = .loaded(try store.update { $0.current = account.id })
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

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

    var body: some View {
        switch model.state {
        case .loaded(let registry):
            Text("New claude sessions use:")
            ForEach(Array(registry.accounts.enumerated()), id: \.element.id) { index, account in
                Toggle(isOn: Binding(get: { registry.current == account.id }, set: { _ in model.use(account) })) {
                    Text([account.label, account.email].compactMap { $0 }.joined(separator: "    "))
                }
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: []) : nil)
            }
        case .failed(let message):
            Text("⚠︎ \(message)")
            Text("Run `acc doctor` in a terminal to fix it.")
        }
        if let error = model.lastError {
            Divider()
            Text("⚠︎ \(error)")
        }
        Divider()
        Button("Show accounts.json in Finder") { model.revealRegistry() }
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
            case .loaded(let registry): Text("✳︎ \(registry.currentAccount.label)")
            case .failed: Text("✳︎ ⚠︎")
            }
        }
    }
}
