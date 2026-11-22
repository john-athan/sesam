import Cocoa
import Carbon.HIToolbox

/// The reflex. ⌨️
///
/// One global hotkey, Option-Space by default, and it is the only way into
/// Sesam that matters.
///
/// Carbon's `RegisterEventHotKey` on purpose: unlike a global `NSEvent`
/// monitor, and unlike an event tap, it needs no Accessibility permission. It
/// is also the only mechanism macOS will honour while another application is
/// full screen. A password manager that cannot be reached from the app you are
/// logging into would be a decoration.
///
/// The trap: registration fails silently when something else already owns the
/// combination, which for Option-Space is usually an input method switcher or
/// another launcher. `isRegistered` is therefore reported rather than assumed,
/// and the menu says so.
final class Hotkey {

    private var ref: EventHotKeyRef?
    private let action: () -> Void

    private(set) var isRegistered = false

    init(keyCode: UInt32 = UInt32(kVK_Space),
         modifiers: UInt32 = UInt32(optionKey),
         action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            let me = Unmanaged<Hotkey>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, context, nil)

        let id = EventHotKeyID(signature: 0x5345534D /* 'SESM' */, id: 1)
        isRegistered = RegisterEventHotKey(keyCode, modifiers, id,
                                           GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
