import Cocoa
import Carbon.HIToolbox

/// The last three feet. 🚚
///
/// Between a selected row and a password in a login form there is a clipboard,
/// another application's focus, and a timer. All three live here.
///
/// **The clipboard is marked as a secret and then taken back.** Every write
/// carries `org.nspasteboard.ConcealedType`, which is the convention clipboard
/// managers watch to know they must not record an entry, and a timer clears it
/// afterwards. The timer checks `changeCount` first: if anything else has
/// written to the pasteboard in the meantime, clearing would throw away
/// somebody else's work, so it does nothing instead.
///
/// **Filling is a paste, not a typing.** Sesam restores the application that
/// was in front when the panel opened, puts the password on the clipboard, and
/// posts one Command-V. The alternative, synthesising the password character by
/// character, sounds cleaner and is worse: it depends on the keyboard layout,
/// it is rejected by fields that ignore synthetic key events one at a time, and
/// it is much slower to arrive. What the paste gives up is that the password
/// does touch the clipboard, which is why it is cleared afterwards and why the
/// previous clipboard contents are put back.
///
/// The trap: posting a synthetic Command-V requires the Accessibility grant,
/// and the copy shortcuts do not. So a fresh install can copy immediately and
/// only Enter sends anybody to System Settings. And the paste has to wait for
/// the other application to actually come forward: posting the keystroke into
/// the gap between `activate()` and the window server agreeing sends
/// Command-V nowhere at all.
enum Deliver {

    /// Seconds before the clipboard is wiped again. 0 means never.
    static var clearAfter: TimeInterval {
        get {
            let stored = UserDefaults.standard.object(forKey: "clearAfter") as? Double
            return stored ?? 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "clearAfter") }
    }

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Put a secret on the clipboard, marked, and schedule its removal.
    static func copy(_ secret: Secret) {
        secret.withString { write($0) }
        scheduleClear()
    }

    /// Put a plain string (a username) on the clipboard. Marked the same way:
    /// a username is not a password, but it is still nobody's business which
    /// accounts you have, and clipboard managers keep history forever.
    static func copy(text: String) {
        write(text)
        scheduleClear()
    }

    /// Bring `app` back to the front and paste `secret` into whatever has focus
    /// there. Returns nil on success, or a message for the user.
    static func paste(_ secret: Secret, into app: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted() else {
            return "Filling needs the Accessibility permission. Copying with Command-C does not."
        }
        // What was on the clipboard, and whether it was one of ours. Restoring
        // a password that Sesam had marked as concealed without the marker
        // would hand it to exactly the clipboard managers the marker exists to
        // keep it away from, and would leave it there with no timer, because
        // the original timer's changeCount no longer matches. That is worse
        // than the copy it is trying to be polite about.
        let board = NSPasteboard.general
        let previous = board.string(forType: .string)
        let previousWasSecret = board.data(forType: Self.concealed) != nil

        secret.withString { write($0) }

        app?.activate()

        // 120 ms is the smallest delay that survived twenty tries here. The
        // keystroke is posted to the session, so it lands wherever the window
        // server thinks the focus is at that instant, which is why this waits
        // for the activation rather than racing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            tap(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let previous else { return clear() }
                write(previous, concealed: previousWasSecret)
                if previousWasSecret { scheduleClear() }
            }
        }
        return nil
    }

    // MARK: - the board

    private static var writtenAt: Int = 0

    private static func write(_ text: String, concealed: Bool = true) {
        let board = NSPasteboard.general
        board.clearContents()
        if concealed { board.setData(Data(), forType: Self.concealed) }
        board.setString(text, forType: .string)
        writtenAt = board.changeCount
    }

    static func clear() {
        NSPasteboard.general.clearContents()
        writtenAt = NSPasteboard.general.changeCount
    }

    private static func scheduleClear() {
        let delay = clearAfter
        guard delay > 0 else { return }
        let mine = writtenAt
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard shouldClear(written: mine, now: NSPasteboard.general.changeCount) else { return }
            clear()
        }
    }

    /// The guard, pulled out so it can be tested without a pasteboard: only
    /// clear what we wrote, and only if nobody has written since.
    static func shouldClear(written: Int, now: Int) -> Bool { written == now }

    private static func tap(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
