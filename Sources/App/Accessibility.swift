import AppKit
import ApplicationServices

/// The doorman. 🚪
///
/// Sesam asks for exactly one permission, for exactly one feature. Copying a
/// password needs nothing. Pasting it into another application means posting a
/// synthetic Command-V, and macOS gates that behind Accessibility.
///
/// So a fresh install works immediately with Command-C, and only pressing
/// Enter sends anybody to System Settings. That split is worth keeping: a
/// password manager that demands to control your computer before it will show
/// you anything is a password manager people quit.
///
/// The trap: the grant is attached to a code identity, not to an app. Sesam is
/// ad-hoc signed and built from source, so its identity is a hash of the
/// binary, and rebuilding it produces a stranger. The switch in System Settings
/// stays on while `AXIsProcessTrusted()` starts answering false. Anybody who
/// rebuilds has to remove the old entry with the minus button and add the new
/// one, and the menu says so rather than leaving them to work it out.
enum Accessibility {

    /// Cheap, no prompt, live: a grant made while Sesam is running flips this
    /// without a restart.
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Ask. Shows the system prompt if the system is willing to show it, and
    /// opens the settings pane either way, because the case where the prompt
    /// stays silent is exactly the case people need help with.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings()
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
