import AccCore
import AppKit
import SwiftUI

/// ✳︎ and the shortest window of the account being worked on, else of the first tool's current account.
struct MenuBarLabel: View {
    @ObservedObject var model: Model

    var body: some View {
        let now = Date()
        let account = model.accountInUse(at: now) ?? model.registry.flatMap { r in r.tools.first.flatMap(r.current(for:)) }
        switch model.state {
        case .failed: Text("✳︎ ⚠︎")
        case .loaded:
            if let window = account.flatMap({ model.monitor.readings[$0.id]?.windows.first }) {
                Text("✳︎ \(Int(window.used(at: now).rounded()))%")
            } else {
                Text("✳︎")
            }
        }
    }
}

/// The menu bar panel: every account's usage at a glance; clicking one offers to make it the pick.
struct UsagePanel: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    /// The one row asking to switch or being renamed, if any.
    @State private var focus: RowFocus?

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                if model.offerTerminal { terminalOffer.padding(.horizontal, 12).padding(.vertical, 6) }
                content(at: context.date)
                if let error = model.lastError {
                    Text(error).problem().padding(.horizontal, 14).padding(.top, 6)
                }
                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.top, 8)
                footer.padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 360)
        .onAppear {
            focus = nil
            model.monitor.refresh()
        }
    }

    /// Asked the first time someone picks an account, since it's then that the terminal not following matters.
    private var terminalOffer: some View {
        let file = model.shell.map { abbreviatingHome($0.hook().file) } ?? "your shell's startup file"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Make your terminal follow this pick?").font(Theme.title).foregroundStyle(Theme.ink(0.9))
            Text("New claude, codex and opencode sessions start on the account you pick once Consolidatex adds one line to \(file). It also turns on Claude Code's status line, which shows each session's account and usage.")
                .font(Theme.caption).foregroundStyle(Theme.ink(0.55)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Add the Line") { model.connectTerminal() }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Not Now") { model.declineTerminal() }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.ink(0.5))
            }
        }
        .padding(10)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("✳︎").foregroundStyle(Theme.claude)
            Text("Consolidatex").font(Theme.title).foregroundStyle(Theme.ink(0.9))
            Spacer()
            Button { model.monitor.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink(0.5))
                    .rotationEffect(.degrees(model.monitor.spinning ? 360 : 0))
                    .animation(model.monitor.spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: model.monitor.spinning)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        switch model.state {
        case .loaded(let registry) where registry.accounts.isEmpty:
            Notice(title: "No accounts yet", detail: "Run acc setup in a terminal, or add one in Manage.")
        case .loaded(let registry):
            ForEach(registry.tools, id: \.self) { tool in
                ToolSection(model: model, registry: registry, tool: tool, now: now, focus: $focus)
            }
        case .failed(let message):
            Notice(title: "The account registry has a problem", detail: "\(message)\nRun acc doctor in a terminal.")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Manage…") {
                openWindow(id: "accounts")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")
            Spacer()
            Menu {
                Button("Quick Switch…  ⌥⌘A") { model.showQuickSwitcher() }
                Button("Last 7 Days…") {
                    openWindow(id: "report")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider()
                Toggle("Switch Automatically at a Limit", isOn: $model.autoSwitch)
                Toggle("Live Claude Usage from Anthropic", isOn: Binding(get: { model.monitor.liveClaude }, set: { model.monitor.liveClaude = $0 }))
                Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { _ in model.toggleOpenAtLogin() }))
                Divider()
                Button("Use the Accounts with the Most Room") { model.useRoomiest() }
                Divider()
                Button("Quit Consolidatex") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Live Claude usage asks Anthropic for each Claude account's limits every 5 minutes, using its own Claude Code login. Off, usage comes only from status lines.")
        }
        .buttonStyle(.plain)
        .font(Theme.caption)
        .foregroundStyle(Theme.ink(0.5))
    }
}

/// A row's moment of interaction. Clicking opens it: what runs on the account now, where its
/// tokens went, and, for an account that isn't the pick, the switch, which asks first because it
/// changes every terminal's next session. Renaming edits the name in place.
struct RowFocus: Equatable {
    enum Mode { case open, renaming }
    let id: String
    let mode: Mode
}

/// Everything a row can ask for, built per account by its section.
private struct RowActions {
    /// Opens or closes the row.
    let toggle: () -> Void
    let open: () -> Void
    /// Makes the account the pick; nil when it already is.
    let switchHere: (() -> Void)?
    let rename: () -> Void
    let commitName: (String) -> Void
    let dismiss: () -> Void
    let logIn: () -> Void
    let reveal: () -> Void
    /// Offered on an account at its limit with a session running: the target's name, and the move.
    let continueElsewhere: (target: String, run: () -> Void)?
    /// Offered on a Claude account with no reading: turns on live usage.
    let checkLive: (() -> Void)?
}

/// One tool's accounts, under a header that counts how many have room.
private struct ToolSection: View {
    @ObservedObject var model: Model
    let registry: Registry
    let tool: Tool
    let now: Date
    @Binding var focus: RowFocus?

    var body: some View {
        let accounts = registry.accounts(for: tool)
        let readings = model.monitor.readings
        let ready = accounts.filter { readings[$0.id].map { !$0.isCapped(at: now) } ?? false }.count
        let next = registry.roomiest(tool, readings, at: now)
        // With one account there's nothing to pick, so "Next session" and "Most tokens left" would only be noise.
        let choosing = accounts.count > 1
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(tool.spec.name.uppercased()).font(Theme.sans(11, .medium)).tracking(0.6).foregroundStyle(Theme.ink(0.45))
                Text("\(accounts.count)")
                    .font(Theme.sans(10, .medium))
                    .foregroundStyle(Theme.ink(0.7))
                    .padding(.horizontal, 5)
                    .background(Theme.selection, in: Capsule())
                Spacer()
                if accounts.contains(where: { readings[$0.id] != nil }) {
                    Text("\(ready)/\(accounts.count) ready").font(Theme.figure).foregroundStyle(ready > 0 ? Theme.good : Theme.bad)
                }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            ForEach(accounts) { account in
                UsageRow(account: account, usage: readings[account.id], identity: model.monitor.identities[account.id],
                         activity: model.monitor.activity[account.id], now: now,
                         isPicked: choosing && registry.isCurrent(account),
                         isNext: choosing && next?.id == account.id && readings[account.id] != nil,
                         isActive: model.monitor.isActive(account, at: now),
                         problem: model.monitor.problems[account.id]?.reason,
                         login: model.logins[account.id],
                         running: model.monitor.running[account.id] ?? [],
                         mode: focus?.id == account.id ? focus?.mode : nil,
                         actions: actions(for: account))
            }
        }
        .padding(.horizontal, 6)
    }

    /// Where a conversation could move when `account` is at its limit and in use.
    private func continueTarget(for account: Account) -> Account? {
        guard Sessions.supports(account.tool), model.monitor.readings[account.id]?.isCapped(at: now) == true,
              model.monitor.isActive(account, at: now)
        else { return nil }
        return registry.roomiest(account.tool, model.monitor.readings, excluding: account.id, at: now)
    }

    private func actions(for account: Account) -> RowActions {
        func set(_ next: RowFocus?) { withAnimation(.easeOut(duration: 0.15)) { focus = next } }
        let picked = registry.isCurrent(account)
        return RowActions(
            toggle: { set(focus == RowFocus(id: account.id, mode: .open) ? nil : RowFocus(id: account.id, mode: .open)) },
            open: { set(RowFocus(id: account.id, mode: .open)) },
            switchHere: picked ? nil : {
                model.use(account)
                set(nil)
            },
            rename: { set(RowFocus(id: account.id, mode: .renaming)) },
            commitName: { name in
                let name = name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, name != account.label { model.rename(account, to: name) }
                set(nil)
            },
            dismiss: { set(nil) },
            logIn: { model.logIn(account) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: account.folder())]) },
            continueElsewhere: continueTarget(for: account).map { target in (target.label, { model.continueElsewhere(account) }) },
            checkLive: account.tool == .claude && !model.monitor.liveClaude ? { model.monitor.liveClaude = true } : nil)
    }
}

private struct UsageRow: View {
    let account: Account
    let usage: Usage?
    let identity: Identity?
    let activity: TranscriptLog.Activity?
    let now: Date
    /// New sessions of its tool start here.
    let isPicked: Bool
    let isNext: Bool
    let isActive: Bool
    let problem: String?
    let login: Model.Login?
    let running: [AppCount]
    let mode: RowFocus.Mode?
    let actions: RowActions
    @State private var hovering = false
    @State private var draft = ""
    /// Set once Return or Esc has decided, so the focus loss that follows doesn't save again.
    @State private var editDone = false
    @FocusState private var nameFocused: Bool

    /// The shortest window: the one a working session runs into first.
    private var headline: Usage.Window? { usage?.windows.first }
    private var isCapped: Bool { usage?.isCapped(at: now) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .renaming {
                summary
            } else {
                Button(action: actions.toggle) { summary }
                    .buttonStyle(.plain)
            }
            if mode == .open {
                details.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isPicked || mode != nil ? Theme.selection : hovering ? Theme.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
        .contextMenu {
            Button("Use for Next Session…", action: actions.open).disabled(actions.switchHere == nil)
            Button("Rename…", action: actions.rename)
            Divider()
            Button("Log In Again", action: actions.logIn)
            Button("Show in Finder", action: actions.reveal)
        }
    }

    /// What runs on the account now, where its tokens went, and the switch.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Running now") {
                if running.isEmpty {
                    Text("nothing").foregroundStyle(Theme.ink(0.45))
                } else {
                    HStack(spacing: 10) {
                        ForEach(running, id: \.launcher) { app in
                            HStack(spacing: 4) {
                                LauncherIcon(launcher: app.launcher)
                                Text(app.count > 1 ? "\(app.launcher.name) · \(app.count) sessions" : app.launcher.name)
                            }
                        }
                    }
                }
            }
            if let split = tokenSplit {
                fact("Last 5 hours") { Text(split) }
            }
            if let switchHere = actions.switchHere {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start new \(account.tool.spec.name) sessions on \(account.label)?")
                        .font(Theme.sans(12, .medium)).foregroundStyle(Theme.ink(0.9))
                    Text("Applies the next time you run \(account.tool.spec.command), in any terminal. Sessions already running keep their account.")
                        .font(Theme.caption).foregroundStyle(Theme.ink(0.55)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Switch", action: switchHere)
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.pick)
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel", action: actions.dismiss)
                            .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.ink(0.5))
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.top, 2)
            } else {
                // The picked account has no switch, and so no Cancel button; Esc still closes the row.
                Button("", action: actions.dismiss).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 9)
    }

    private func fact<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.ink(0.4)).frame(width: 78, alignment: .leading)
            content().foregroundStyle(Theme.ink(0.75))
        }
        .font(Theme.caption)
    }

    /// "T3 Code 68% · Terminal 22% · Claude desktop 10% of 1.9M output tokens", from the transcripts.
    private var tokenSplit: String? {
        guard let activity, let shares = UsageFormat.shares(activity.byOrigin) else { return nil }
        return shares + " of \(UsageFormat.tokens(activity.outputTokens)) output tokens"
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleLine
            if mode == .renaming {
                Text("Return saves · Esc cancels").font(Theme.caption).foregroundStyle(Theme.ink(0.4))
            } else {
                detailLine
            }
            if let headline { Meter(percent: isCapped ? 100 : headline.used(at: now)) }
            if let forecast = usage?.forecast(at: now, active: isActive) {
                Text("\(forecast.window.label) fills \(Format.capTime(forecast.capsAt, from: now)) at this pace")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
                    .help("Projected from average use since the window opened")
            }
            loginStatus
            if let move = actions.continueElsewhere {
                Button("Continue this conversation on \(move.target)", action: move.run)
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.pick)
                    .help("Moves the latest conversation to \(move.target) and resumes it there, in Terminal")
            }
            if let problem { Text(problem).problem() }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var loginStatus: some View {
        switch login {
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Finish logging in in your browser").font(Theme.caption).foregroundStyle(Theme.ink(0.55))
            }
        case .inTerminal:
            Text("Finish logging in in the Terminal window").font(Theme.caption).foregroundStyle(Theme.ink(0.55))
        case .failed(let reason):
            Text("Login didn't finish: \(reason)").problem()
        case nil:
            EmptyView()
        }
    }

    private var help: String {
        let action = isPicked ? "New \(account.tool.spec.name) sessions start on this account"
                              : "Click to start new \(account.tool.spec.name) sessions on \(account.label)"
        let more = "Right-click to rename, log in again or show its folder"
        guard let activity else { return "\(action)\n\(more)" }
        return "\(UsageFormat.tokens(activity.outputTokens)) output tokens · \(activity.requests) requests in the last 5h\n\(action)\n\(more)"
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if mode == .renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.title)
                    .foregroundStyle(Theme.ink(0.9))
                    .focused($nameFocused)
                    .onSubmit {
                        editDone = true
                        actions.commitName(draft)
                    }
                    .onExitCommand {
                        editDone = true
                        actions.dismiss()
                    }
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                    .padding(.horizontal, -5)
                    .onAppear {
                        draft = account.label
                        editDone = false
                        nameFocused = true
                    }
                    // Clicking elsewhere keeps what was typed, as in Finder.
                    .onChange(of: nameFocused) { focused in
                        guard !focused, !editDone else { return }
                        editDone = true
                        actions.commitName(draft)
                    }
            } else {
                // The name gives way before the badges do.
                Text(account.label).font(Theme.title).foregroundStyle(Theme.ink(0.9)).lineLimit(1).layoutPriority(-1)
            }
            if let plan = identity?.plan {
                Text(plan).font(Theme.caption).foregroundStyle(Theme.ink(0.4)).fixedSize()
            }
            if !running.isEmpty {
                RunningApps(apps: running)
            }
            if isPicked {
                Badge(text: "Next session", systemImage: "checkmark.circle.fill", tint: Theme.pick, filled: true)
                    .help("The next \(account.tool.spec.command) you start, in any terminal, runs on this account")
            } else if isNext {
                Badge(text: "Most tokens left", systemImage: "arrow.up.right", tint: Theme.good, filled: false)
                    .help("The account with the most of its usage limits still unused")
            }
            Spacer()
            let used = headline.map { $0.used(at: now) }
            Text(isCapped ? "Capped" : used.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(Theme.mono(12, .medium))
                .foregroundStyle(isCapped ? Theme.bad : used.map(Theme.level) ?? Theme.ink(0.35))
        }
    }

    /// Who it is, the other windows, and when the headline window resets.
    private var detailLine: some View {
        HStack(spacing: 8) {
            // Masked at rest so the panel is safe to screen-share; hovering the row reveals it.
            Text((identity?.email ?? account.email).map { hovering ? $0 : Format.masked($0) } ?? account.id)
                .font(Theme.caption)
                .foregroundStyle(Theme.ink(hovering ? 0.7 : 0.45))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if usage == nil, let checkLive = actions.checkLive {
                Button("Check with Anthropic", action: checkLive)
                    .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Color.accentColor)
                    .help("Turns on live Claude usage: every 5 minutes, each Claude account's login asks Anthropic for its limits")
            } else if usage == nil {
                Text(UsageFormat.empty(tool: account.tool)).font(Theme.caption).foregroundStyle(Theme.ink(0.35))
            }
            ForEach(usage?.windows.dropFirst().map { $0 } ?? [], id: \.label) { window in
                let used = window.used(at: now)
                (Text(window.label).foregroundColor(Theme.ink(0.3)) + Text(" \(Int(used.rounded()))%"))
                    .font(Theme.figure)
                    .foregroundStyle(used >= 85 ? Theme.level(used) : Theme.ink(0.5))
                    .help(window.resetsAt.map { "\(window.label) resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" } ?? window.label)
            }
            if let headline, let resetsAt = headline.resetsAt, resetsAt > now, headline.used(at: now) > 0 {
                (Text("↻ ") + Text(timerInterval: now...resetsAt, countsDown: true))
                    .font(Theme.figure)
                    .foregroundStyle(Theme.ink(0.4))
                    .help("\(headline.label) resets \(resetsAt.formatted(date: .omitted, time: .shortened))")
            }
        }
    }
}

/// The apps running sessions on an account, as icons with a count, so who uses which
/// subscription shows without a click.
private struct RunningApps: View {
    let apps: [AppCount]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(apps.prefix(3), id: \.launcher) { app in
                HStack(spacing: 1) {
                    LauncherIcon(launcher: app.launcher)
                    if app.count > 1 { Text("\(app.count)").font(Theme.sans(9, .semibold)).foregroundStyle(Theme.ink(0.5)) }
                }
            }
        }
        .fixedSize()
        .help("Running now: " + UsageFormat.running(apps))
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}

private struct LauncherIcon: View {
    let launcher: Launcher

    var body: some View {
        if let bundle = launcher.bundle {
            Image(nsImage: AppIcons.icon(for: bundle)).resizable().frame(width: 14, height: 14)
        } else {
            Image(systemName: "gearshape").font(.system(size: 10)).foregroundStyle(Theme.ink(0.45)).frame(width: 14, height: 14)
        }
    }
}

/// A small capsule: filled for a state the account is in, outlined for a suggestion.
private struct Badge: View {
    let text: String
    let systemImage: String
    let tint: Color
    let filled: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8.5, weight: .bold))
            Text(text)
        }
        .font(Theme.sans(10, .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .fixedSize()
        .background(filled ? tint.opacity(0.14) : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0.25 : 0.5), lineWidth: 0.75))
    }
}

/// A thin bar for the share of a limit used, coloured by `Theme.level`.
private struct Meter: View {
    let percent: Double

    var body: some View {
        Capsule().fill(Theme.stroke)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(percent >= 85 ? Theme.level(percent) : Theme.ink(0.4))
                        .frame(width: geo.size.width * min(percent, 100) / 100)
                }
            }
            .animation(.easeOut(duration: 0.3), value: percent)
    }
}

private struct Notice: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.title).foregroundStyle(Theme.ink(0.8))
            Text(detail).font(Theme.caption).foregroundStyle(Theme.ink(0.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// One ink stepped by opacity, hairline strokes, small type, and colour reserved for status.
enum Theme {
    static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
    static let stroke = ink(0.07)
    static let selection = ink(0.08)
    static let hover = ink(0.05)
    static let good = Color(red: 0.06, green: 0.73, blue: 0.51)
    static let warn = Color(red: 0.91, green: 0.77, blue: 0.28)
    static let bad = Color(red: 0.96, green: 0.25, blue: 0.37)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// The account new sessions start on. Fixed rather than the system accent, so it never reads as a warning.
    static let pick = Color(nsColor: .systemBlue)
    static let radius: CGFloat = 6

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static let title = sans(13, .medium)
    static let caption = sans(11)
    static let figure = mono(11)

    /// Calm until it matters: neutral below 85%, yellow near the cap, red at it.
    static func level(_ percent: Double) -> Color {
        percent >= 100 ? bad : percent >= 85 ? warn : ink(0.55)
    }
}

enum Format {
    /// Hide the mailbox, keep the domain: "name@cynco.io" → "••••@cynco.io".
    static func masked(_ email: String) -> String {
        email.firstIndex(of: "@").map { "••••" + email[$0...] } ?? "••••"
    }

    /// "in ~1h 20m" when it's today's problem, "~Thu 14:00" when it's days out.
    static func capTime(_ date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 12 * 3600 else {
            let rounded = max(60, (seconds / 60).rounded() * 60)
            return "in ~" + Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        }
        return "~" + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

extension Text {
    /// Something on this account needs attention.
    func problem() -> some View {
        font(Theme.caption).foregroundStyle(Theme.bad).lineLimit(2)
    }
}
