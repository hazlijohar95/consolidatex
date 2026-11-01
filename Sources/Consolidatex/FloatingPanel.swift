import AppKit
import SwiftUI

/// A borderless window in the middle of the screen, above other apps, that closes on Esc or a click
/// anywhere else, as Spotlight does. The keyboard shortcuts open their windows in one.
@MainActor
final class FloatingPanel {
    private var panel: NSPanel?
    private var resign: NSObjectProtocol?

    /// Shows what `content` makes, given a way to close it, or closes it if it's showing.
    func toggle<Content: View>(_ content: (_ close: @escaping () -> Void) -> Content) {
        if panel?.isVisible == true { return close() }
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.onCancel = { [weak self] in self?.close() }
        // The window follows the view's size as it changes, keeping its top edge.
        let host = NSHostingView(rootView: content { [weak self] in self?.close() })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        self.panel = panel
    }

    private func close() {
        resign.map(NotificationCenter.default.removeObserver)
        resign = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// A borderless window can't take keyboard focus unless it says so.
    private final class KeyPanel: NSPanel {
        var onCancel: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel() }
    }
}
