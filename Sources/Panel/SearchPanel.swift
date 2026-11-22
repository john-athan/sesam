import Cocoa
import Carbon.HIToolbox

/// The bar. 🔎
///
/// The whole user interface, minus a menu bar icon: a field, up to eight rows,
/// and four keys that do something with the selected row.
///
/// **It must take the keyboard without taking the job.** The panel is a
/// `nonactivatingPanel` that can become key, and Sesam is an accessory app with
/// no Dock icon, so bringing it up does not push the app you were in out of the
/// way of anything except focus. The application that was in front is recorded
/// before the panel appears, because it is where Enter has to paste and where
/// Escape has to hand focus back.
///
/// **Command keys are caught at the window, not in the field.** A text field's
/// editor answers Command-C with "copy the selected text" long before any
/// delegate hears about it, so the four shortcuts are intercepted in
/// `performKeyEquivalent`, which the window sees first. The arrow keys are the
/// mirror image: the field editor swallows those, so they come back through
/// `control(_:textView:doCommandBy:)`.
///
/// The trap: an `NSPanel` that is ordered out while it is key leaves focus
/// nowhere in particular, and the app you came from does not necessarily get it
/// back. Hiding therefore reactivates the recorded application explicitly.
final class SearchPanelController: NSObject, NSTextFieldDelegate {

    private let panel: SesamPanel
    private let field = NSTextField()
    private let results = ResultsView()
    private let effect = NSVisualEffectView()

    /// Who was in front when the panel opened. Enter pastes there.
    private(set) var caller: NSRunningApplication?

    private var shown: [Item] = []
    private var noteTimer: Timer?
    /// True while a source is being asked for a password. A second Enter while
    /// the first one is still waiting on a Touch ID prompt would ask twice.
    private var busy = false

    override init() {
        panel = SesamPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width,
                                height: PanelLayout.height(rows: 0)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // A window that never appears in a screen recording or a screenshot.
        // The one line in Sesam that stops a password being in somebody else's
        // video call.
        panel.sharingType = .none
        panel.delegate = self

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = PanelLayout.corner
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        field.font = PanelTheme.field
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search your vaults"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.maximumNumberOfLines = 1
        effect.addSubview(field)
        effect.addSubview(results)

        results.onClick = { [weak self] _ in self?.fill() }
    }

    // MARK: - showing and hiding

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String = "") {
        // Only remember somebody else as the caller. Without this, opening the
        // panel while Sesam is already frontmost (after its own unlock prompt,
        // or after an alert) would record Sesam as the app to paste into, and
        // Enter would type the password into nothing.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            caller = front
        }
        field.stringValue = query
        rerank()
        Vault.shared.refreshIfStale()

        layout()
        panel.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        panel.makeFirstResponder(field)
    }

    func hide() {
        noteTimer?.invalidate()
        results.note = nil
        panel.orderOut(nil)
        caller?.activate()
    }

    /// Called by the vault when the index changes underneath an open panel.
    func refreshed() {
        guard isVisible else { return }
        rerank()
    }

    // MARK: - the list

    private func rerank() {
        shown = Ranker.rank(Vault.shared.items, query: field.stringValue,
                            frecency: Frecency.count(for:))
        // Last, so it never takes the first row away from a real match, and
        // only while there is something to unlock.
        if let keepass = Vault.shared.source(.keePass) as? KeePassSource,
           Vault.shared.isEnabled(.keePass), !keepass.isUnlocked,
           KeePassSource.databasePath != nil {
            shown.append(.unlockKeePass)
        }
        results.items = shown
        results.selected = 0
        results.note = nil
        layout()
    }

    private func layout() {
        let rows = shown.count
        // The display the mouse is on, which is where Spotlight appears and
        // therefore where anybody expects this. `NSScreen.main` is the screen
        // holding the key window, so on a second monitor it puts the panel on
        // the wrong one about half the time; `panel.screen` is nil until the
        // panel has been shown at least once.
        let here = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screen = (here ?? panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(PanelLayout.frame(on: screen, rows: rows), display: true)

        let size = panel.contentView?.bounds.size ?? .zero
        field.frame = NSRect(x: PanelLayout.margin + 6,
                             y: size.height - PanelLayout.fieldHeight + 12,
                             width: size.width - PanelLayout.margin * 2 - 12,
                             height: 38)
        results.frame = NSRect(x: 0, y: 0, width: size.width,
                               height: size.height - PanelLayout.fieldHeight)
    }

    func controlTextDidChange(_ obj: Notification) { rerank() }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.insertNewline(_:)):
            fill(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        results.selected = (results.selected + delta + shown.count) % shown.count
        results.note = nil
    }

    private var selection: Item? {
        shown.indices.contains(results.selected) ? shown[results.selected] : nil
    }

    // MARK: - the four keys

    /// Answered by the panel before the field editor gets a look in.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        switch (event.charactersIgnoringModifiers ?? "", flags.contains(.shift)) {
        case ("c", false): copyPassword(); return true
        case ("b", false): copyUsername(); return true
        case ("t", false): copyCode(); return true
        case ("n", false): newItem(); return true
        case ("e", false): replacePassword(); return true
        case ("r", true):  reveal(); return true
        default: return false
        }
    }

    private func copyPassword() {
        guard let item = selection else { return }
        withSecret(of: item) { [self] credential in
            Deliver.copy(credential.password)
            Frecency.used(item.key)
            hide()
        }
    }

    private func copyUsername() {
        guard let item = selection else { return }
        if let name = item.username, !name.isEmpty {
            Deliver.copy(text: name)
            Frecency.used(item.key)
            hide()
            return
        }
        withSecret(of: item) { [self] credential in
            guard let name = credential.username, !name.isEmpty else {
                complain("That entry has no username.")
                return
            }
            Deliver.copy(text: name)
            Frecency.used(item.key)
            hide()
        }
    }

    private func fill() {
        guard let item = selection else { return }
        let target = caller
        withSecret(of: item) { [self] credential in
            hide()
            if let problem = Deliver.paste(credential.password, into: target) {
                complain(problem)
            } else {
                Frecency.used(item.key)
            }
        }
    }

    /// The second factor, which is the other half of most logins and the half
    /// that otherwise means picking up a phone.
    private func copyCode() {
        guard let item = selection else { return }
        fetch(item, { try Vault.shared.totp(for: item) }) { [self] code in
            Deliver.copy(text: code)
            Frecency.used(item.key)
            hide()
        }
    }

    // MARK: - writing

    /// A new login, in the vault of your choosing, with a password neither you
    /// nor Sesam had to think of. What was typed into the search field becomes
    /// the title, because the usual way to arrive here is having searched for
    /// something that is not saved yet.
    private func newItem() {
        let prefill = field.stringValue.trimmingCharacters(in: .whitespaces)
        hide()
        guard let (kind, draft) = NewItemSheet.ask(title: prefill) else { return }
        // The fetch is part of the same background step as the write: reading
        // the new password back means another subprocess, and doing that on the
        // main thread would freeze the panel it is about to reopen.
        perform({
            let item = try Vault.shared.create(draft, in: kind)
            return (item, try Vault.shared.secret(for: item))
        }) { [self] item, credential in
            announce(item, credential, "created, password copied")
        }
    }

    /// The rotation. On a change password form: press this, the vault mints a
    /// new one, the clipboard holds it, paste it into the second box.
    private func replacePassword() {
        guard let item = selection, !item.isAction else { return }
        // Asked before the confirmation rather than after it: offering to
        // replace a password and then refusing is worse than saying so first.
        guard Vault.shared.canWrite(item.source) else {
            report(VaultError(item.source == .keychain
                              ? "Sesam does not write to the Keychain"
                              : "\(item.source.label) is not open for writing",
                              routine: true), in: results.selected)
            return
        }
        hide()

        let alert = NSAlert()
        alert.messageText = "Replace the password for \(item.title)?"
        alert.informativeText = "\(item.source.label) generates the new one and Sesam copies it. "
                              + "The old password is gone from the entry, though "
                              + "\(item.source.label) keeps its own history."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        perform({
            try Vault.shared.regenerate(for: item)
            return (item, try Vault.shared.secret(for: item))
        }) { [self] item, credential in
            announce(item, credential, "new password copied")
        }
    }

    /// Both writes end the same way: the new password on the clipboard, the
    /// index rebuilt, and the panel back up with the entry in front of you, so
    /// that something visible says what happened. Waiting for the rebuild
    /// matters: a 1Password item does not exist in the list Sesam searches
    /// until the next `op item list` has come back.
    private func announce(_ item: Item, _ credential: Credential, _ what: String) {
        Deliver.copy(credential.password)
        Frecency.used(item.key)
        Vault.shared.refresh { [self] in
            show(query: item.title)
            guard let row = shown.firstIndex(where: { $0.id == item.id }) else { return }
            results.selected = row
            results.note = (row, what)
            noteTimer?.invalidate()
            noteTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                self?.results.note = nil
            }
        }
    }

    /// The background half of a write. Same shape as `fetch`, without a row to
    /// hang a note on: the panel is closed while a sheet is up.
    private func perform<T>(_ work: @escaping () throws -> T,
                            _ body: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result(catching: work)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let value): body(value)
                case .failure(let error): self.complain(error.localizedDescription)
                }
            }
        }
    }

    /// Show the password in the row for ten seconds, for the times it has to be
    /// typed into something that is not this Mac.
    private func reveal() {
        guard let item = selection else { return }
        let row = results.selected
        withSecret(of: item) { [self] credential in
            results.note = (row, credential.password.withString { $0 })
            noteTimer?.invalidate()
            noteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.results.note = nil
            }
        }
    }

    /// Every action funnels through here, so there is exactly one place that
    /// asks a vault for a password and exactly one place that reports being
    /// refused.
    ///
    /// **It leaves the main thread, and that is not optional.** `op` answers in
    /// milliseconds while its session is warm and puts up a Touch ID prompt
    /// when it is not, and that prompt waits for a finger. Fetching on the main
    /// thread would freeze the panel, the menu bar and quite possibly the
    /// prompt itself for as long as nobody touched the sensor. So the row says
    /// what it is waiting for, the fetch happens elsewhere, and `body` runs
    /// back on the main thread with the answer.
    private func withSecret(of item: Item, _ body: @escaping (Credential) -> Void) {
        fetch(item, { try Vault.shared.secret(for: item) }, body)
    }

    /// Ask a vault something slow, and do something with the answer.
    ///
    /// **It leaves the main thread, and that is not optional.** `op` answers in
    /// milliseconds while its session is warm and puts up a Touch ID prompt
    /// when it is not, and that prompt waits for a finger. Fetching on the main
    /// thread would freeze the panel, the menu bar and quite possibly the
    /// prompt itself for as long as nobody touched the sensor. So the row says
    /// what it is waiting for, the work happens elsewhere, and `body` runs back
    /// on the main thread with the answer.
    private func fetch<T>(_ item: Item,
                          _ work: @escaping () throws -> T,
                          _ body: @escaping (T) -> Void) {
        // The unlock row is not a password, so it stops here rather than being
        // handled once in each of the keys that lead in.
        guard !item.isAction else {
            let query = field.stringValue
            hide()
            Unlock.keePass { [weak self] opened in
                if opened { self?.show(query: query) }
            }
            return
        }
        guard !busy else { return }
        busy = true

        let row = results.selected
        // Only say "waiting" if it is actually slow. A note that flashes up on
        // every keystroke is noise.
        let waiting = DispatchWorkItem { [weak self] in
            guard let self, self.busy else { return }
            self.results.note = (row, "waiting for \(item.source.label)…")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: waiting)

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result(catching: work)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                waiting.cancel()
                if self.results.note?.index == row { self.results.note = nil }
                switch outcome {
                case .success(let value): body(value)
                case .failure(let error): self.report(error, in: row)
                }
            }
        }
    }

    /// An answer nobody needs a dialog for goes under the row that gave it, and
    /// the panel stays open so the next key can be pressed. Everything else is
    /// a real failure and gets said properly.
    private func report(_ error: Error, in row: Int) {
        guard let vault = error as? VaultError, vault.routine else {
            complain(error.localizedDescription)
            return
        }
        results.note = (row, vault.message)
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.results.note = nil
        }
    }

    /// The trap this fixes: `runModal` on an accessory application that is not
    /// frontmost puts the alert up behind whatever is, and then blocks the main
    /// thread waiting for a button nobody can see. Sesam hands focus back to
    /// the app you came from every time the panel closes, so without the
    /// activation here that is the normal case rather than the rare one.
    private func complain(_ message: String) {
        panel.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = "Sesam"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension SearchPanelController: NSWindowDelegate {
    /// Clicking anywhere else means you are done here.
    func windowDidResignKey(_ notification: Notification) { hide() }
}

/// A borderless panel has to be told it may hold the keyboard, and told where
/// to send the four Command shortcuts before its text field claims them.
final class SesamPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = delegate as? SearchPanelController, controller.handle(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
