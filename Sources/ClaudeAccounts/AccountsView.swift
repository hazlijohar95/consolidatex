import AccCore
import SwiftUI

struct AccountsView: View {
    @ObservedObject var model: Model
    @State private var selection: String?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.state {
            case .loaded(let registry):
                List(selection: $selection) {
                    ForEach(Array(registry.accounts.enumerated()), id: \.element.id) { index, account in
                        AccountRow(model: model, account: account, position: index + 1,
                                   isCurrent: registry.current == account.id,
                                   isPrimary: registry.primary.id == account.id)
                            .tag(account.id)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                footer(registry)
            case .failed(let message):
                ContentUnavailable(message: message) { model.revealRegistry() }
            }
        }
        .frame(minWidth: 680, minHeight: 380)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
        .alert("Config synced", isPresented: Binding(get: { model.syncReport != nil }, set: { if !$0 { model.dismissSyncReport() } })) {
            Button("OK") { model.dismissSyncReport() }
        } message: {
            Text(model.syncReport ?? "")
        }
        .onAppear { model.checkHealth() }
    }

    @ViewBuilder
    private func footer(_ registry: Registry) -> some View {
        let selected = selection.flatMap(registry.account(id:))
        let removable = selected.map { $0.id != registry.current && $0.id != registry.primary.id } ?? false
        Divider()
        HStack(spacing: 8) {
            Button { adding = true } label: { Image(systemName: "plus") }
                .help("Add a subscription")
            Button {
                if let selected { model.remove(selected) }
            } label: { Image(systemName: "minus") }
                .disabled(!removable)
                .help(removable ? "Remove from acc (its config folder is kept)"
                                : "The current and primary accounts cannot be removed")
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .font(.callout)
            }
            Spacer()
            if model.checking { ProgressView().controlSize(.small) }
            Button("Check") { model.checkHealth() }
                .disabled(model.checking)
            Button("Sync Config") { model.syncConfig() }
                .disabled(model.checking)
                .help("Share \(registry.primary.label)'s CLAUDE.md, settings, skills, plugins and MCP servers with every account")
        }
        .buttonStyle(.bordered)
        .padding(10)
    }
}

struct AccountRow: View {
    @ObservedObject var model: Model
    let account: Account
    let position: Int
    let isCurrent: Bool
    let isPrimary: Bool
    @State private var label = ""

    var body: some View {
        let health = model.health[account.id]
        HStack(spacing: 12) {
            Text("\(position)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            StatusDot(health: health, checking: model.checking)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $label)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit { model.rename(account, to: label) }
                Text(subtitle(health))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            UsageBars(usage: model.usage[account.id])
            trailing(health)
                .frame(width: 118, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .onAppear { label = account.label }
        .onChange(of: account.label) { label = $0 }
        .contextMenu {
            Button("Use for New Sessions") { model.use(account) }.disabled(isCurrent)
            Button("Log In Again") { model.logIn(account) }
        }
    }

    private func subtitle(_ health: AccountHealth?) -> String {
        var parts = [account.id, account.email ?? "email unknown"]
        if isPrimary { parts.append("primary") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func trailing(_ health: AccountHealth?) -> some View {
        switch model.logins[account.id] {
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finish in browser").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Button("Retry Login") { model.logIn(account) }
                .help(message)
        case nil:
            if health?.loggedIn == false {
                Button("Log In") { model.logIn(account) }
            } else if isCurrent {
                Text("Current")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            } else {
                Button("Use") { model.use(account) }
            }
        }
    }
}

struct StatusDot: View {
    let health: AccountHealth?
    let checking: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(detail)
    }

    private var color: Color {
        guard let health else { return .secondary.opacity(0.4) }
        if !health.problems.isEmpty { return .red }
        if !health.issues.isEmpty { return .orange }
        return .green
    }

    private var detail: String {
        guard let health else { return checking ? "Checking…" : "Not checked yet" }
        let lines = health.problems + health.issues
        return lines.isEmpty ? "Logged in, sharing config" : lines.joined(separator: "\n")
    }
}

struct UsageBars: View {
    let usage: Usage?

    var body: some View {
        let now = Date()
        VStack(alignment: .trailing, spacing: 3) {
            if let usage {
                bar("5h", usage.fiveHour, now)
                bar("7d", usage.sevenDay, now)
            } else {
                Text("no usage yet").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 130)
        .help(UsageFormat.summary(usage))
    }

    @ViewBuilder
    private func bar(_ name: String, _ window: Usage.Window?, _ now: Date) -> some View {
        if let window {
            let used = window.used(at: now)
            HStack(spacing: 6) {
                Text(name).font(.caption2).foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                ProgressView(value: min(used, 100), total: 100)
                    .tint(used >= 90 ? .red : used >= 70 ? .orange : .green)
                Text("\(Int(used.rounded()))%").font(.caption2).monospacedDigit().frame(width: 30, alignment: .trailing)
            }
        }
    }
}

struct AddAccountSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var id = ""
    @State private var idEdited = false

    var body: some View {
        let registry = model.registry
        let problem = validation(registry)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Subscription").font(.headline)
            Text("acc creates a separate Claude Code config for it, shares your rules, settings, skills, plugins and MCP servers, then opens the browser to log in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $label, prompt: Text("e.g. Hello Team"))
                    .onChange(of: label) { new in
                        if !idEdited { id = registry?.suggestedID(for: new) ?? "" }
                    }
                TextField("Short name", text: Binding(get: { id }, set: { id = $0; idEdited = true }),
                          prompt: Text("used as claude @name and acc name"))
                LabeledContent("Config folder") {
                    Text("~/.claude-\(id.isEmpty ? "…" : id)").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let problem, !label.isEmpty {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add and Log In") {
                    model.add(label: label.trimmingCharacters(in: .whitespaces), id: id)
                    if model.lastError == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func validation(_ registry: Registry?) -> String? {
        guard var registry else { return "the account registry could not be read" }
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name" }
        do {
            try registry.add(Account(id: id, label: label, configDir: "~/.claude-\(id)"))
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

struct ContentUnavailable: View {
    let message: String
    let reveal: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text("The account registry has a problem").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Button("Show accounts.json in Finder", action: reveal)
            Text("Or run `acc doctor` in a terminal.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
