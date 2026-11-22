import Foundation
import ServiceManagement

/// The habit. 🌅
///
/// Thin wrapper over `SMAppService.mainApp`, the macOS 13 way to be a login
/// item: no helper bundle, no AppleScript poking at System Events, no
/// permission dialog beyond the toggle in System Settings.
///
/// A password manager bound to a hotkey is worth having only if the hotkey
/// works after a restart, so this is one of the few settings that is worth
/// nudging people towards.
enum LoginItem {

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Flip it. Returns nil on success, or a message to show the user.
    static func toggle() -> String? {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else         { try SMAppService.mainApp.register() }
            return nil
        } catch {
            return "\(error.localizedDescription)\n\nMove Sesam.app to /Applications and try again."
        }
    }
}
