import AccCore
import SwiftUI

/// The ⌥⌘A window: the accounts of every tool with a choice, arrow keys to move, Return to switch.
struct QuickSwitchView: View {
    @ObservedObject var model: Model
    let close: () -> Void
    @State private var selection: String?
    @FocusState private var listFocused: Bool

    private var accounts: [Account] {
        guard let registry = model.registry else { return [] }
        return registry.ordered.filter { registry.accounts(for: $0.tool).count > 1 }
    }

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 8) {
            Text("Start new sessions on…").font(Theme.title).foregroundStyle(Theme.ink(0.9))
            if accounts.isEmpty {
                Text("No tool has more than one account yet.").font(Theme.caption).foregroundStyle(Theme.ink(0.5))
            } else {
                List(selection: $selection) {
                    ForEach(accounts) { account in row(account, now: now).tag(account.id) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                .frame(height: min(CGFloat(accounts.count) * 30 + 8, 330))
            }
            Text("↑↓ choose · Return switches · Esc closes").font(Theme.caption).foregroundStyle(Theme.ink(0.4))
            // Return and Esc, with no visible buttons.
            Button("", action: switchToSelection).keyboardShortcut(.defaultAction).opacity(0).frame(width: 0, height: 0)
            Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            selection = initialSelection(at: now)
            listFocused = true
        }
    }

    private func row(_ account: Account, now: Date) -> some View {
        let usage = model.monitor.readings[account.id]
        // The fullest window, which is what "most tokens left" ranks by.
        let used = usage.map { $0.load(at: now) }
        let capped = usage?.isCapped(at: now) ?? false
        return HStack(spacing: 8) {
            Text(account.tool.rawValue).font(Theme.figure).foregroundStyle(Theme.ink(0.4)).frame(width: 64, alignment: .leading)
            Text(account.label).font(Theme.sans(13)).lineLimit(1)
            if model.registry?.isCurrent(account) == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.pick).help("Next session")
            }
            Spacer()
            Text(capped ? "Capped" : used.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(Theme.mono(12, .medium))
                .foregroundStyle(capped ? Theme.bad : used.map(Theme.level) ?? Theme.ink(0.35))
        }
    }

    /// The account with the most left, in the first tool that has a choice: what you most likely want next.
    private func initialSelection(at now: Date) -> String? {
        guard let registry = model.registry, let tool = accounts.first?.tool else { return nil }
        return (registry.roomiest(tool, model.monitor.readings, excluding: registry.current(for: tool)?.id, at: now) ?? accounts.first)?.id
    }

    private func switchToSelection() {
        guard let id = selection, let account = model.registry?.account(id: id) else { return }
        if model.registry?.isCurrent(account) == false { model.use(account) }
        close()
    }
}
