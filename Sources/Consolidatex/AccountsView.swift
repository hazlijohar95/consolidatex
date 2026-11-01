import AccCore
import SwiftUI

struct AccountsView: View {
    @ObservedObject var model: Model
    @State private var selection: String?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.state {
            case .loaded(let registry) where registry.accounts.isEmpty:
                EmptyState(installed: model.installedTools) { adding = true }
                footer(registry)
            case .loaded(let registry):
                List(selection: $selection) {
                    ForEach(registry.tools, id: \.self) { tool in
                        Section(tool.spec.name) {
                            ForEach(registry.accounts(for: tool)) { account in
                                AccountRow(model: model, account: account,
                                           position: registry.ordered.firstIndex(of: account)! + 1,
                                           isCurrent: registry.isCurrent(account),
                                           isPrimary: registry.primary(for: tool)?.id == account.id)
                                    .tag(account.id)
                            }
                            .onMove { model.move(tool, from: $0, to: $1) }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                footer(registry)
            case .failed(let message):
                RegistryProblem(message: message) { model.revealRegistry() }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
        .alert("Config shared", isPresented: Binding(get: { model.syncReport != nil }, set: { if !$0 { model.dismissSyncReport() } })) {
            Button("OK") { model.dismissSyncReport() }
        } message: {
            Text(model.syncReport ?? "")
        }
        .onAppear { model.checkHealth() }
        .onDisappear { model.dismissError() }
    }

    @ViewBuilder
    private func footer(_ registry: Registry) -> some View {
        let selected = selection.flatMap(registry.account(id:))
        let removable = selected.map { a in
            let others = registry.accounts(for: a.tool).count > 1
            return !others || (!registry.isCurrent(a) && registry.primary(for: a.tool)?.id != a.id)
        } ?? false
        Divider()
        HStack(spacing: 8) {
            Button { adding = true } label: { Image(systemName: "plus") }
                .help("Add a subscription")
                .disabled(model.installedTools.isEmpty)
            Button {
                if let selected { model.remove(selected) }
            } label: { Image(systemName: "minus") }
                .disabled(!removable)
                .help(removable ? "Remove from Consolidatex (its folder is kept)"
                                : "A tool's current and primary accounts can't be removed while it has others")
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .font(.callout)
            }
            Spacer()
            if model.checking { ProgressView().controlSize(.small) }
            Button("Check") { model.checkHealth() }
                .disabled(model.checking || registry.accounts.isEmpty)
            Button("Sync Config") { model.syncConfig() }
                .disabled(model.checking || registry.accounts.isEmpty)
                .help("Share each tool's rules, settings, skills, plugins and MCP servers from its primary account")
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
            UsageBars(usage: model.monitor.readings[account.id], tool: account.tool)
            trailing(health)
                .frame(width: 128, alignment: .trailing)
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
        var parts = [account.id, account.email ?? health?.detail ?? "not checked yet"]
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
        case .inTerminal:
            Button("Done? Check") { model.checkHealth() }
                .help("Finish logging in in the Terminal window, then check")
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
    let tool: Tool

    var body: some View {
        // Its own clock: a window that resets changes nothing that's published.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: 3) {
                if let usage, !usage.windows.isEmpty {
                    ForEach(usage.windows, id: \.label) { window in bar(window, context.date) }
                } else {
                    Text(UsageFormat.empty(tool: tool)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 134)
            .help(UsageFormat.summary(usage, tool: tool, at: context.date))
        }
    }

    private func bar(_ window: Usage.Window, _ now: Date) -> some View {
        let used = window.used(at: now)
        return HStack(spacing: 6) {
            Text(window.label).font(.caption2).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            ProgressView(value: min(used, 100), total: 100)
                .tint(Theme.level(used))
            Text("\(Int(used.rounded()))%").font(.caption2).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
    }
}

struct AddAccountSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var tool: Tool = .claude
    @State private var label = ""
    @State private var id = ""
    @State private var idEdited = false

    var body: some View {
        let registry = model.registry
        let problem = validation(registry)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Subscription").font(.headline)
            Text("Consolidatex creates a separate folder for it, shares your existing config, then opens the login.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Tool", selection: $tool) {
                    ForEach(model.installedTools, id: \.self) { Text($0.spec.name).tag($0) }
                }
                TextField("Name", text: $label, prompt: Text("e.g. Work"))
                    .onChange(of: label) { new in
                        if !idEdited { id = registry?.suggestedID(for: new) ?? "" }
                    }
                TextField("Short name", text: Binding(get: { id }, set: { id = $0; idEdited = true }),
                          prompt: Text("for acc and \(tool.spec.command) @name"))
                LabeledContent("Folder") {
                    Text("~/\(tool.spec.newAccountPrefix)\(id.isEmpty ? "…" : id)").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let hint = tool.spec.loginHint {
                Label(hint, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem, !label.isEmpty {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tool.spec.loginNeedsTerminal ? "Add and Log In in Terminal" : "Add and Log In") {
                    model.add(tool: tool, label: label.trimmingCharacters(in: .whitespaces), id: id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if let first = model.installedTools.first { tool = first } }
    }

    private func validation(_ registry: Registry?) -> String? {
        guard var registry else { return "the account registry could not be read" }
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name" }
        do {
            try registry.add(registry.newAccount(tool: tool, label: label, id: id))
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

struct EmptyState: View {
    let installed: [Tool]
    let add: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.badge.key").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No accounts yet").font(.title3.weight(.semibold))
            Text(installed.isEmpty
                 ? "Install Claude Code, Codex or opencode first."
                 : "Run `acc setup` in a terminal to import the accounts you already have, or add one here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add a Subscription", action: add).disabled(installed.isEmpty)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RegistryProblem: View {
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
