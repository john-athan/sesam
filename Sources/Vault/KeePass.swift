import Foundation

/// The database, opened as its owner. 🗄️
///
/// KeePassXC has a socket that browsers talk to, and it is the obvious way in
/// until you look at what it can answer. `get-logins` takes a URL and returns
/// entries matching that URL; there is no call that lists a database, and in
/// 2.7.12 there is no `get-database-entries` at all. A search bar over a source
/// that can only be asked "what do you have for github.com" is not a search
/// bar. So Sesam reads the `.kdbx` itself.
///
/// It reads it through `keepassxc-cli`, which ships inside KeePassXC.app, and
/// not through a KDBX reader written here. That file format is Argon2id, then
/// AES or ChaCha20, then an HMAC block chain, then gzip, then XML, and every
/// one of those is a place to be subtly wrong with somebody's passwords. The
/// binary that the format's own authors ship is already on this Mac.
///
/// **One call, and then the process is gone.** `export -f xml` hands over the
/// whole database once. There is no long lived child holding an unlocked
/// database, and no pipe to a shell that could be talked to by something else.
/// What is held instead is this object: titles and usernames as text, and each
/// password in a `Secret` that `lock()` overwrites.
///
/// **The master password is never an argument and never touches disk.** It goes
/// to the child on stdin and the buffer is wiped by the caller as soon as this
/// returns.
///
/// The trap: the export is plaintext XML on a pipe. It is never written to a
/// file, never logged, and the `Data` holding it is overwritten before it goes
/// out of scope. A version of this that used a temporary file, which is the
/// obvious way to hand megabytes between two processes, would leave the entire
/// database unencrypted in `/tmp` for as long as the filesystem felt like it.
final class KeePassSource: Source {

    let kind = SourceKind.keePass

    static let candidates = [
        "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli",
        "/opt/homebrew/bin/keepassxc-cli",
        "/usr/local/bin/keepassxc-cli",
    ]

    static var databasePath: String? {
        get { UserDefaults.standard.string(forKey: "keepassDatabase") }
        set { UserDefaults.standard.set(newValue, forKey: "keepassDatabase") }
    }

    static var keyFilePath: String? {
        get { UserDefaults.standard.string(forKey: "keepassKeyFile") }
        set { UserDefaults.standard.set(newValue, forKey: "keepassKeyFile") }
    }

    private struct Held {
        /// Where `keepassxc-cli` addresses this entry: the group path and the
        /// title, which is what its `edit` command takes. Not the UUID, which
        /// it has no way to look up.
        let path: String
        let username: String
        let password: Secret
        /// The one-time seed, held like the password because it is one: it
        /// mints codes for as long as it exists.
        let otp: Secret?
    }

    /// Guards the three fields below, which an index writes from the work
    /// queue while the menu reads them from the main thread.
    private let mutex = Lock()
    private var held: [String: Held] = [:]
    private var count = 0
    private var items: [Item] = []
    /// Bumped by every lock. An unlock that started before a lock and finished
    /// after it must not hand over its result: opening a database takes a
    /// second or two of Argon2id, and a lid closed in that window would
    /// otherwise be followed by the whole decrypted database arriving in a
    /// Sesam that had already reported itself locked.
    private var generation = 0

    var state: SourceState {
        guard Shell.locate(Self.candidates) != nil else {
            return .notConfigured("KeePassXC is not installed")
        }
        guard let path = Self.databasePath else { return .notConfigured("no database chosen") }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed("the database file has moved")
        }
        return mutex.around { held.isEmpty ? .locked : .ready(count) }
    }

    var isUnlocked: Bool { mutex.around { !held.isEmpty } }

    /// Open the database and keep what it says. The password bytes belong to
    /// the caller, who wipes them; nothing is kept here but the result.
    func unlock(password: [UInt8]) throws {
        guard let cli = Shell.locate(Self.candidates) else {
            throw VaultError("KeePassXC is not installed, so there is no keepassxc-cli to read the database with.")
        }
        guard let database = Self.databasePath else {
            throw VaultError("Choose a KeePassXC database first.")
        }

        let generation = mutex.around { self.generation }

        var arguments = ["export", "-q", "-f", "xml"]
        if let keyFile = Self.keyFilePath, !keyFile.isEmpty {
            arguments += ["-k", keyFile]
        }
        arguments.append(database)

        var stdin = password
        stdin.append(0x0A)
        var result = try Shell.run(cli, arguments, stdin: stdin, timeout: 60)
        for i in stdin.indices { stdin[i] = 0 }

        guard result.ok else {
            throw VaultError(result.err.isEmpty
                             ? "KeePassXC could not open that database."
                             : result.err)
        }

        let entries = KdbxXML.parse(result.out)
        // The decrypted database was on this pipe. Overwrite it now rather
        // than waiting for the allocator. `Data` is copy on write, so this is
        // in place only while nothing else is holding the same buffer, which
        // is why it happens here and not before the parser has let go.
        result.out.resetBytes(in: 0..<result.out.count)

        var built: [Item] = []
        var store: [String: Held] = [:]
        for entry in entries where !entry.password.isEmpty || !entry.username.isEmpty {
            let id = entry.uuid.isEmpty ? "\(entry.group)/\(entry.title)" : entry.uuid
            built.append(Item(id: id,
                              title: entry.title,
                              username: entry.username.isEmpty ? nil : entry.username,
                              url: entry.url.isEmpty ? nil : entry.url,
                              container: entry.group.isEmpty ? "KeePassXC" : entry.group,
                              source: .keePass))
            let path = [entry.group, entry.title].filter { !$0.isEmpty }.joined(separator: "/")
            store[id] = Held(path: path,
                             username: entry.username,
                             password: Secret(entry.password),
                             otp: entry.otp.isEmpty ? nil : Secret(entry.otp))
        }
        // The export and the parse happened outside the lock; only the swap is
        // inside it, and only if nobody locked in the meantime.
        let stale = mutex.around { () -> Bool in
            guard generation == self.generation else { return true }
            for entry in held.values {
                entry.password.wipe()
                entry.otp?.wipe()
            }
            held = store
            items = built
            count = built.count
            return false
        }
        guard !stale else {
            for entry in store.values {
                entry.password.wipe()
                entry.otp?.wipe()
            }
            throw VaultError("Sesam locked while that database was opening. Try again.",
                             routine: true)
        }
    }

    func index() throws -> [Item] { mutex.around { items } }

    // MARK: - writing

    /// How Sesam gets the master password when it needs it again. Set once by
    /// `MenuBarApp`, so this file stays free of any user interface and the
    /// prompt stays in one place.
    var askForKey: () -> [UInt8]? = { nil }

    /// The generator is KeePassXC's, matching the defaults in its own settings.
    /// Sesam never invents a password.
    static let generate = ["-g", "-L", "30", "-l", "-U", "-n", "-s"]

    var destinations: [String] {
        let (empty, items) = mutex.around { (held.isEmpty, self.items) }
        guard !empty else { return [] }
        // The root group is offered as an empty string, which the sheet shows
        // as the database's own name.
        let groups = Set(items.compactMap { item -> String? in
            guard let container = item.container, container != "KeePassXC" else { return nil }
            return container
        })
        return [""] + groups.sorted()
    }

    func create(_ draft: Draft) throws -> Item {
        try Self.checkAddressable(draft.title)
        let path = Self.path(for: draft)
        try write(Self.addArguments(draft), entry: path)
        // `unlock` swaps both fields under the mutex, so they are read under it.
        let found = mutex.around { items.first(where: { held[$0.id]?.path == path }) }
        guard let item = found else {
            throw VaultError("KeePassXC saved the entry but Sesam cannot find it again.")
        }
        return item
    }

    func regenerate(for item: Item) throws {
        try Self.checkAddressable(item.title)
        guard let entry = mutex.around({ held[item.id] }) else {
            throw VaultError("KeePassXC is locked. Unlock it from the panel.")
        }
        try write(Self.editArguments, entry: entry.path)
    }

    /// Built here, and tested, for the same reason as 1Password's: what makes
    /// this safe is that `-g` is in the list and a password never is.
    static func addArguments(_ draft: Draft) -> [String] {
        var arguments = ["add", "-q"] + generate
        if !draft.username.isEmpty { arguments += ["-u", draft.username] }
        if !draft.url.isEmpty { arguments += ["--url", draft.url] }
        return arguments
    }

    static let editArguments = ["edit", "-q"] + generate

    /// `keepassxc-cli` addresses an entry by a slash separated path through the
    /// groups, and offers no way to escape a slash inside a title. So an entry
    /// called `Bank/Root Password` in the root group produces the same address
    /// as an entry called `Root Password` inside a group called `Bank`, and a
    /// write aimed at one would land on the other. Reading such an entry is
    /// fine, since that goes by UUID through Sesam's own index; only writing is
    /// refused, and it says why rather than picking one.
    static func checkAddressable(_ title: String) throws {
        guard !title.contains("/") else {
            throw VaultError("a title with a slash in it cannot be addressed safely in "
                             + "KeePassXC. Rename the entry first.", routine: true)
        }
    }

    /// Where `keepassxc-cli` will put it: a path relative to the root group,
    /// which is why the root shows up as an empty destination.
    static func path(for draft: Draft) -> String {
        [draft.destination, draft.title].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// One shape for both writes: ask for the master password, run the command
    /// with it on stdin, then re-open the database so the index matches what is
    /// now in the file. The key is wiped whatever happens.
    ///
    /// The trap: this is called from a background queue, and the prompt has to
    /// run on the main one. Blocking here is safe because the main thread is
    /// not waiting on this work, it is running its own run loop underneath the
    /// panel that started it.
    private func write(_ arguments: [String], entry: String) throws {
        guard let cli = Shell.locate(Self.candidates),
              let database = Self.databasePath else {
            throw VaultError("Choose a KeePassXC database first.")
        }
        let asked = Thread.isMainThread ? askForKey() : DispatchQueue.main.sync(execute: askForKey)
        guard var key = asked else { throw VaultError("Cancelled.") }
        defer { for i in key.indices { key[i] = 0 } }

        var full = arguments
        if let keyFile = Self.keyFilePath, !keyFile.isEmpty { full += ["-k", keyFile] }
        full += [database, entry]

        var stdin = key
        stdin.append(0x0A)
        let result = try Shell.run(cli, full, stdin: stdin, timeout: 60)
        for i in stdin.indices { stdin[i] = 0 }
        guard result.ok else {
            throw VaultError(result.err.isEmpty ? "KeePassXC refused the change." : result.err)
        }
        // The file has changed underneath the index, so read it again with the
        // key that is still in hand rather than asking for it twice.
        try unlock(password: key)
    }

    func secret(for item: Item) throws -> Credential {
        guard let entry = mutex.around({ held[item.id] }) else {
            throw VaultError("KeePassXC is locked. Unlock it from the menu bar.")
        }
        return Credential(username: entry.username.isEmpty ? nil : entry.username,
                          password: entry.password)
    }

    func totp(for item: Item) throws -> String {
        guard let entry = mutex.around({ held[item.id] }) else {
            throw VaultError("KeePassXC is locked. Unlock it from the panel.")
        }
        guard let seed = entry.otp,
              let settings = seed.withString({ TOTP.settings(from: $0) }) else {
            throw VaultError("no one-time code in this entry", routine: true)
        }
        return TOTP.code(settings)
    }

    func lock() {
        mutex.around {
            generation += 1
            for entry in held.values {
                entry.password.wipe()
                entry.otp?.wipe()
            }
            held = [:]
            items = []
            count = 0
        }
    }
}
