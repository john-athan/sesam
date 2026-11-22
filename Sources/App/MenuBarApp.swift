import Cocoa
import UniformTypeIdentifiers

/// The doorkeeper. 🔑
///
/// Owns the status item, the hotkey, the panel and the clock that locks
/// everything again. Keep this file readable: it is the map of the whole app.
///
/// **The menu is a status display first and a settings pane second.** The one
/// question worth answering without opening anything is "can Sesam reach my
/// vaults right now", so each source is one line carrying its own state, and
/// clicking that line switches it off. There is no preferences window because
/// there is nothing in it that needs more room than this.
///
/// **Everything expensive happens on open.** The menu is rebuilt in
/// `menuWillOpen`, which is the only moment its contents are read, so a Sesam
/// nobody is looking at costs one status item and one idle timer.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let panel = SearchPanelController()
    private var hotkey: Hotkey?

    /// The clock behind auto-lock. One timer, one minute, no polling of
    /// anything else: it asks how long ago the last search was and nothing
    /// more.
    private var idleTimer: Timer?
    private var lastUse = Date()

    private let defaults = UserDefaults.standard

    /// Minutes of quiet before the vaults are dropped. 0 means never.
    private var lockAfter: Int {
        get { defaults.object(forKey: "lockAfter") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "lockAfter") }
    }

    private let header = NSMenuItem(title: "Sesam", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        Hardening.apply()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "key.horizontal.fill",
                                           accessibilityDescription: "Sesam")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotkey = Hotkey { [weak self] in self?.summon() }

        // KeePassXC has to ask for the master password again to write, and this
        // file is where asking lives. Wired once, so that neither the source
        // nor the panel has to know about the other.
        (Vault.shared.source(.keePass) as? KeePassSource)?.askForKey = { Unlock.masterKey() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(vaultChanged),
            name: Vault.changed, object: nil)

        // The two moments a Mac stops being watched. Both drop everything.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(lockNow),
                              name: NSWorkspace.willSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(lockNow),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        // `sesam lock` and `sesam search` from a terminal, which is a second
        // binary and cannot reach into this process any other way.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(lockNow),
            name: NSNotification.Name("io.github.john-athan.sesam.lock"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(summonFromMenu),
            name: NSNotification.Name("io.github.john-athan.sesam.search"), object: nil)

        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.lockIfIdle()
        }

        Vault.shared.refresh()
    }

    // MARK: - the hotkey

    private func summon() {
        lastUse = Date()
        panel.toggle()
    }

    @objc private func vaultChanged() {
        panel.refreshed()
        render()
    }

    private func render() {
        let count = Vault.shared.items.count
        header.title = count == 0 ? "Sesam, locked"
                                  : "Sesam, \(count) item\(count == 1 ? "" : "s")"
    }

    // MARK: - locking

    @objc private func lockNow() {
        Vault.shared.lock()
        panel.hide()
        Deliver.clear()
    }

    private func lockIfIdle() {
        guard lockAfter > 0, !Vault.shared.items.isEmpty else { return }
        guard Date().timeIntervalSince(lastUse) > Double(lockAfter) * 60 else { return }
        lockNow()
    }

    // MARK: - the menu

    func menuWillOpen(_ menu: NSMenu) {
        render()
        menu.removeAllItems()

        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for kind in SourceKind.allCases {
            let state = Vault.shared.state(kind)
            let item = NSMenuItem(title: "\(state.dot)  \(kind.label)   \(state.line)",
                                  action: #selector(toggleSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = Vault.shared.isEnabled(kind) ? .on : .off
            menu.addItem(item)
        }
        if Vault.shared.isEnabled(.keychain) {
            let note = NSMenuItem(
                title: "Safari and iCloud logins are not readable by any app",
                action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        add(menu, "Search…", #selector(summonFromMenu), key: " ", modifiers: [.option])
        add(menu, "Rebuild index", #selector(rebuild))
        if let keepass = Vault.shared.source(.keePass) as? KeePassSource,
           Vault.shared.isEnabled(.keePass), !keepass.isUnlocked,
           KeePassSource.databasePath != nil {
            add(menu, "Unlock KeePassXC…", #selector(unlockKeePass))
        }
        add(menu, Vault.shared.items.isEmpty ? "Locked" : "Lock now", #selector(lockNow))
            .isEnabled = !Vault.shared.items.isEmpty

        menu.addItem(.separator())
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        add(menu, "Quit Sesam", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    private func settingsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let lock = NSMenuItem(title: "Lock when idle", action: nil, keyEquivalent: "")
        let lockMenu = NSMenu()
        for minutes in [5, 15, 60, 0] {
            let title = minutes == 0 ? "Never" : "After \(minutes) minutes"
            let item = add(lockMenu, title, #selector(setLockAfter(_:)))
            item.representedObject = minutes
            item.state = lockAfter == minutes ? .on : .off
        }
        lock.submenu = lockMenu
        menu.addItem(lock)

        let clip = NSMenuItem(title: "Clear the clipboard", action: nil, keyEquivalent: "")
        let clipMenu = NSMenu()
        for seconds in [15.0, 30.0, 60.0, 0.0] {
            let title = seconds == 0 ? "Never" : "After \(Int(seconds)) seconds"
            let item = add(clipMenu, title, #selector(setClearAfter(_:)))
            item.representedObject = seconds
            item.state = Deliver.clearAfter == seconds ? .on : .off
        }
        clip.submenu = clipMenu
        menu.addItem(clip)

        menu.addItem(.separator())
        add(menu, "Choose the KeePassXC database…", #selector(chooseDatabase))
        if TouchID.isAvailable {
            let remember = add(menu, "Remember its password, behind Touch ID",
                               #selector(toggleRemember))
            remember.state = TouchID.isWanted ? .on : .off
        }
        if KeePassSource.keyFilePath == nil {
            add(menu, "Add a key file…", #selector(chooseKeyFile))
        } else {
            add(menu, "Forget the key file", #selector(forgetKeyFile))
        }

        menu.addItem(.separator())
        add(menu, "Launch at login", #selector(toggleLogin)).state = LoginItem.isEnabled ? .on : .off
        let access = add(menu, Accessibility.isGranted
                         ? "Filling is allowed"
                         : "Allow filling with Enter…", #selector(askAccessibility))
        access.state = Accessibility.isGranted ? .on : .off
        if let hotkey, !hotkey.isRegistered {
            let warning = NSMenuItem(title: "Option-Space is taken by another app",
                                     action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let icons = add(menu, "Fetch site icons", #selector(toggleIcons))
        icons.state = Icons.isEnabled ? .on : .off
        if Icons.isEnabled {
            let note = NSMenuItem(title: "Each site is asked for its own icon, once",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        add(menu, "Forget usage history", #selector(forgetHistory))

        root.submenu = menu
        return root
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String = "", modifiers: NSEvent.ModifierFlags = [],
                     target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    // MARK: - what the menu does

    @objc private func summonFromMenu() { summon() }

    @objc private func rebuild() {
        lastUse = Date()
        Vault.shared.refresh()
    }

    @objc private func toggleSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = SourceKind(rawValue: raw) else { return }
        Vault.shared.setEnabled(!Vault.shared.isEnabled(kind), kind)
    }

    @objc private func setLockAfter(_ sender: NSMenuItem) {
        lockAfter = sender.representedObject as? Int ?? 15
    }

    @objc private func setClearAfter(_ sender: NSMenuItem) {
        Deliver.clearAfter = sender.representedObject as? Double ?? 30
    }

    @objc private func toggleLogin() {
        guard let problem = LoginItem.toggle() else { return }
        let alert = NSAlert()
        alert.messageText = "Sesam could not change the login item"
        alert.informativeText = problem
        alert.runModal()
    }

    @objc private func askAccessibility() {
        if Accessibility.isGranted { Accessibility.openSettings() } else { Accessibility.request() }
    }

    @objc private func forgetHistory() { Frecency.forget() }

    /// Switching it off throws the cache away as well. Leaving a folder of
    /// icons behind would leave the list of services on disk after somebody
    /// decided they did not want it there.
    @objc private func toggleIcons() {
        Icons.isEnabled = !Icons.isEnabled
        if !Icons.isEnabled { Icons.forget() }
    }

    /// Switching it on stores the master password at the next successful
    /// unlock, rather than asking for one now: the moment somebody types it is
    /// the moment there is something to store.
    @objc private func toggleRemember() {
        TouchID.isWanted = !TouchID.isWanted
    }

    @objc private func unlockKeePass() {
        lastUse = Date()
        Unlock.keePass()
    }

    @objc private func chooseDatabase() {
        let kdbx = UTType(filenameExtension: "kdbx") ?? .data
        guard let path = pick(types: [kdbx], prompt: "Choose") else { return }
        KeePassSource.databasePath = path
        (Vault.shared.source(.keePass) as? KeePassSource)?.lock()
        Vault.shared.refresh()
    }

    @objc private func chooseKeyFile() {
        guard let path = pick(types: [], prompt: "Use as key file") else { return }
        KeePassSource.keyFilePath = path
        (Vault.shared.source(.keePass) as? KeePassSource)?.lock()
        Vault.shared.refresh()
    }

    @objc private func forgetKeyFile() {
        KeePassSource.keyFilePath = nil
        (Vault.shared.source(.keePass) as? KeePassSource)?.lock()
        Vault.shared.refresh()
    }

    private func pick(types: [UTType], prompt: String) -> String? {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.prompt = prompt
        if !types.isEmpty { open.allowedContentTypes = types }
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK else { return nil }
        return open.url?.path
    }
}
