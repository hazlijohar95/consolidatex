import AccCore
import Foundation
import UserNotifications

/// The app's notifications: an account came off its limit, the app moved new sessions on its own,
/// or a busy account hit its limit with a conversation that can move to another.
@MainActor
enum Notices {
    /// Notifications need an app bundle; a bare `swift run` has none.
    private static let center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    nonisolated private static let capped = "capped"

    /// What "Continue" does. The app sets it at launch.
    static var onContinue: ((_ target: String, _ conversation: Sessions.Conversation) -> Void)?

    static func prepare() {
        center?.delegate = Presenter.shared
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let action = UNNotificationAction(identifier: "continue", title: "Continue There", options: [.foreground])
        center?.setNotificationCategories([UNNotificationCategory(identifier: capped, actions: [action], intentIdentifiers: [])])
    }

    static func ready(_ account: Account, _ usage: Usage?) {
        post("ready-\(account.id)", title: "\(account.label) is ready",
             body: "Its \(account.tool.spec.name) limit has reset" + (usage.map { " (\(UsageFormat.summary($0, tool: account.tool)))" } ?? "") + ".")
    }

    static func switched(from old: Account, to new: Account, returning: Bool, until: Date?) {
        if returning {
            post("switch-\(new.tool.rawValue)", title: "Back on \(new.label)",
                 body: "Its limit has reset, so new \(new.tool.spec.name) sessions start there again.")
        } else {
            let until = until.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            post("switch-\(new.tool.rawValue)", title: "New \(new.tool.spec.name) sessions now start on \(new.label)",
                 body: "\(old.label) is at its limit\(until). Consolidatex switches back once it resets.")
        }
    }

    /// The app moved conversations off `account` on its own: `opened` resumed in `app`, and `failure`
    /// says why the others didn't open.
    static func continued(_ account: Account, on target: Account, opened: Int, failure: String?, in app: String) {
        let title = "\(account.label) is at its limit"
        if opened == 0 {
            return post("limit-\(account.id)", title: title, body: failure.map { "Its conversations couldn't continue on \(target.label): \($0)." }
                ?? "\(target.label) has room, but Consolidatex couldn't find a conversation to move.")
        }
        let conversations = opened == 1 ? "Its conversation continues" : "Its \(opened) conversations continue"
        let rest = failure.map { " Others didn't open: \($0)." } ?? ""
        post("limit-\(account.id)", title: title, body: "\(conversations) on \(target.label), in new \(app) windows.\(rest)")
    }

    /// `target` is nil when no other account has room; `conversation`, when none was found to move.
    static func atLimit(_ account: Account, continueOn target: Account?, conversation: Sessions.Conversation?) {
        guard let target else {
            return post("limit-\(account.id)", title: "\(account.label) is at its limit",
                        body: "No other \(account.tool.spec.name) account has room right now.")
        }
        guard let conversation else {
            return post("limit-\(account.id)", title: "\(account.label) is at its limit",
                        body: "\(target.label) has room, but Consolidatex couldn't find the conversation to move.")
        }
        let folder = URL(fileURLWithPath: conversation.folder).lastPathComponent
        post("limit-\(account.id)", title: "\(account.label) is at its limit",
             body: "Continue the conversation in \(folder) on \(target.label)?", category: capped,
             info: ["target": target.id, "id": conversation.id, "folder": conversation.folder])
    }

    private static func post(_ id: String, title: String, body: String, category: String? = nil, info: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
        static let shared = Presenter()

        /// Without this, macOS drops banners while the panel is open, because the app is frontmost then.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }

        /// Clicking an at-limit notification, or its Continue button, moves the conversation.
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let content = response.notification.request.content
            guard content.categoryIdentifier == Notices.capped,
                  [UNNotificationDefaultActionIdentifier, "continue"].contains(response.actionIdentifier),
                  let target = content.userInfo["target"] as? String, let id = content.userInfo["id"] as? String,
                  let folder = content.userInfo["folder"] as? String
            else { return }
            await MainActor.run { Notices.onContinue?(target, Sessions.Conversation(id: id, folder: folder)) }
        }
    }
}
