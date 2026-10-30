import Carbon.HIToolbox

/// A shortcut that works from any app, through Carbon's hot-key API, which needs no accessibility
/// permission. It lasts as long as the app, so it never unregisters.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            // Carbon delivers hot keys on the main thread's run loop.
            MainActor.assumeIsolated { Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x4143_4358), id: 1)  // "ACCX"
        guard installed == noErr,
              RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
        else { return nil }
    }
}
