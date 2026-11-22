import Cocoa

/// The one question Sesam asks. 🔒
///
/// KeePassXC is the only source with a key that nobody else is holding: macOS
/// unlocked the keychain at login and the 1Password app holds its own. So once
/// a session, this asks for the master password.
///
/// It is a sheetless `NSAlert` with a secure field, on purpose: a whole
/// password prompt window would be another thing to design, to focus correctly
/// and to get wrong, and this is the same control the rest of macOS uses.
///
/// The trap that cannot be closed here: `NSSecureTextField` hands back a
/// `String`, and a `String` cannot be overwritten. The bytes are copied out and
/// the copy is what travels; the field's own copy is released and not scrubbed.
/// Saying so is better than implying otherwise, and the exposure lasts as long
/// as it takes `keepassxc-cli` to answer.
enum Unlock {

    /// Ask, open, and say whether it worked. The bytes are wiped here whatever
    /// happens next, including when the database refuses them, so no caller has
    /// to remember to do it.
    ///
    /// Both ways in end up here: the menu bar item, and the row the panel shows
    /// when KeePassXC is configured but locked. That second one is the one that
    /// matters, because it means Option-Space is the whole interface.
    static func keePass(then: @escaping (Bool) -> Void = { _ in }) {
        guard let source = Vault.shared.source(.keePass) as? KeePassSource,
              let database = KeePassSource.databasePath else { return then(false) }

        // A remembered password is tried first and asked for second. A refused
        // or cancelled fingerprint is not an error, it is somebody choosing to
        // type instead.
        let name = URL(fileURLWithPath: database).lastPathComponent
        let remembered = TouchID.isWanted
            ? TouchID.recall(reason: "unlock \(name) in Sesam")
            : nil
        guard let password = remembered ?? ask(for: database) else { return then(false) }

        // Opening a database is Argon2id and then a whole file, which is a
        // second or two of work. On the main thread that is a frozen menu bar
        // immediately after somebody typed their master password, which reads
        // as "it did not take it".
        DispatchQueue.global(qos: .userInitiated).async {
            var key = password
            defer { for i in key.indices { key[i] = 0 } }

            do {
                try source.unlock(password: key)
                if TouchID.isWanted && remembered == nil { _ = TouchID.remember(key) }
                DispatchQueue.main.async {
                    Vault.shared.refresh()
                    then(true)
                }
            } catch {
                DispatchQueue.main.async {
                    // A stored password that no longer opens the database is
                    // worse than no stored password: it would fail silently
                    // every time, and always at the moment somebody is in a
                    // hurry.
                    if remembered != nil { TouchID.forget() }
                    let alert = NSAlert()
                    alert.messageText = "Sesam could not open that database"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    then(false)
                }
            }
        }
    }

    /// The master password, from the fingerprint if it is remembered there and
    /// from the keyboard otherwise. The caller wipes it.
    ///
    /// Writing to a KeePassXC database needs it a second time, because Sesam
    /// deliberately does not keep it after the database has been read. That is
    /// the cost of not holding a master password, and it is paid on the rare
    /// operation rather than on every search.
    static func masterKey() -> [UInt8]? {
        guard let database = KeePassSource.databasePath else { return nil }
        let name = URL(fileURLWithPath: database).lastPathComponent
        return TouchID.recall(reason: "change an entry in \(name)") ?? ask(for: database)
    }

    /// Returns the password as bytes, which the caller must wipe, or nil if the
    /// prompt was dismissed.
    static func ask(for database: String) -> [UInt8]? {
        let alert = NSAlert()
        alert.messageText = "Unlock \(URL(fileURLWithPath: database).lastPathComponent)"
        alert.informativeText = "Sesam reads the database once and keeps only what it found. "
                              + "It locks again on sleep, on screen lock, and when idle."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Master password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let typed = field.stringValue
        guard !typed.isEmpty else { return nil }
        return Array(typed.utf8)
    }
}
