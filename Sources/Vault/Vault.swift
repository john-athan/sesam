import Foundation

/// The keyring. 🔗
///
/// One list, built from every source that is switched on, and the lock that
/// empties it. Everything above this line (the panel, the menu, the CLI) sees
/// one array of `Item` and never learns which program produced it.
///
/// **The index is built on a background queue and read on the main one.** That
/// is the only concurrency rule in Sesam and it is kept by having exactly one
/// writer: `refresh` does its slow work off the main thread and then hops back
/// to assign `items`. Nothing else assigns.
///
/// **Lock is a real state, not a screensaver.** `lock()` drops the merged list,
/// tells every source to let go of whatever it was holding, and posts the
/// change so the menu bar stops claiming to know anything. A locked Sesam knows
/// the names of nothing. The keychain source is the exception it has to be:
/// macOS unlocked that at login and Sesam has no say in it, so it comes back on
/// the next search by itself.
final class Vault {

    static let shared = Vault()

    /// Posted on the main thread whenever `items` or any source's state moved.
    static let changed = Notification.Name("io.github.john-athan.sesam.vaultChanged")

    private(set) var items: [Item] = []
    private(set) var isRefreshing = false
    /// When the merged list was last built. `nil` means never, or locked.
    private(set) var indexedAt: Date?

    private let sources: [SourceKind: Source] = [
        .onePassword: OnePasswordSource(),
        .keePass: KeePassSource(),
        .keychain: KeychainSource(),
    ]

    private let work = DispatchQueue(label: "io.github.john-athan.sesam.index", qos: .userInitiated)
    private var lastError: [SourceKind: String] = [:]
    /// Callers waiting for the list to be rebuilt, usually because they just
    /// wrote to a vault and want to see what they wrote.
    private var pending: [() -> Void] = []
    /// Bumped by every lock, for the same reason `KeePassSource` keeps one: an
    /// index that started before a lock must not be published after it.
    private var generation = 0

    private init() {}

    // MARK: - what the menu asks

    func source(_ kind: SourceKind) -> Source? { sources[kind] }

    func state(_ kind: SourceKind) -> SourceState {
        guard isEnabled(kind) else { return .off }
        guard let source = sources[kind] else { return .notConfigured("not built yet") }
        if let error = lastError[kind] { return .failed(error) }
        return source.state
    }

    /// Sources are on by default: a password manager that hides your passwords
    /// until you find a checkbox is a bad first run. The stored key is the
    /// negation for exactly that reason, since `UserDefaults.bool` starts false.
    func isEnabled(_ kind: SourceKind) -> Bool {
        !UserDefaults.standard.bool(forKey: "off.\(kind.rawValue)")
    }

    func setEnabled(_ on: Bool, _ kind: SourceKind) {
        UserDefaults.standard.set(!on, forKey: "off.\(kind.rawValue)")
        if !on { sources[kind]?.lock() }
        refresh()
    }

    // MARK: - the list

    /// What opening the panel asks for. Indexing 1Password means a subprocess
    /// that takes a few seconds and, when its session has expired, a Touch ID
    /// prompt; doing that on every Option-Space would make the hotkey a
    /// question rather than a reflex. So the list is rebuilt when it is stale
    /// and otherwise left alone. "Rebuild index" in the menu ignores this.
    func refreshIfStale(_ interval: TimeInterval = 300) {
        guard let indexedAt, Date().timeIntervalSince(indexedAt) < interval else {
            refresh()
            return
        }
    }

    func refresh(then: (() -> Void)? = nil) {
        if let then { pending.append(then) }
        guard !isRefreshing else { return }
        isRefreshing = true
        announce()

        let generation = self.generation
        work.async { [self] in
            var merged: [Item] = []
            var errors: [SourceKind: String] = [:]
            for kind in SourceKind.allCases {
                guard isEnabled(kind), let source = sources[kind] else { continue }
                do { merged += try source.index() }
                catch { errors[kind] = error.localizedDescription }
            }
            DispatchQueue.main.async {
                self.isRefreshing = false
                guard generation == self.generation else {
                    // Locked while this was running. Publishing now would put
                    // the list of every account back on screen a moment after
                    // the screen locked.
                    self.pending = []
                    self.announce()
                    return
                }
                self.items = merged
                self.lastError = errors
                self.indexedAt = Date()
                self.announce()
                let waiting = self.pending
                self.pending = []
                for callback in waiting { callback() }
            }
        }
    }

    func secret(for item: Item) throws -> Credential {
        guard let source = sources[item.source] else {
            throw VaultError("\(item.source.label) is not connected.")
        }
        return try source.secret(for: item)
    }

    func totp(for item: Item) throws -> String {
        guard let source = sources[item.source] else {
            throw VaultError("\(item.source.label) is not connected.")
        }
        return try source.totp(for: item)
    }

    /// Every place a new entry could go, as (source, destination) pairs, in the
    /// order the sheet should offer them.
    func destinations() -> [(SourceKind, String)] {
        SourceKind.allCases
            .filter { isEnabled($0) }
            .flatMap { kind in (sources[kind]?.destinations ?? []).map { (kind, $0) } }
    }

    /// Whether a source will accept a write at all right now. The keychain
    /// never will, and KeePassXC will not while it is locked.
    func canWrite(_ kind: SourceKind) -> Bool {
        isEnabled(kind) && !(sources[kind]?.destinations.isEmpty ?? true)
    }

    func create(_ draft: Draft, in kind: SourceKind) throws -> Item {
        guard let source = sources[kind] else {
            throw VaultError("\(kind.label) is not connected.")
        }
        return try source.create(draft)
    }

    func regenerate(for item: Item) throws {
        guard let source = sources[item.source] else {
            throw VaultError("\(item.source.label) is not connected.")
        }
        try source.regenerate(for: item)
    }

    func lock() {
        generation += 1
        items = []
        lastError = [:]
        indexedAt = nil
        for source in sources.values { source.lock() }
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: Vault.changed, object: nil)
    }
}
