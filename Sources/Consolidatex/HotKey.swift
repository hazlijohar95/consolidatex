import Carbon.HIToolbox

/// A shortcut that works from any app, through Carbon's hot-key API, which needs no accessibility
/// permission. It lasts as long as the app, so it never unregisters.
@MainActor
final class HotKey {
    private static var nextID: UInt32 = 1
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            // Carbon delivers hot keys on the main thread's run loop. Every shortcut's handler sees every
            // press, and the first to claim one ends it, so each passes on presses that aren't its own.
            return MainActor.assumeIsolated {
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                guard pressedID.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                hotKey.action()
                return noErr
            }
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4143_4358), id: id)  // "ACCX"
        guard installed == noErr,
              RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr
        else { return nil }
    }
}
