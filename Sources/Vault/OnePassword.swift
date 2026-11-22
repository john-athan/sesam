import Foundation

/// The subscription. 🔐
///
/// 1Password is the one source that already has a supported way in: `op`, the
/// official CLI, talking to the desktop app over its own authenticated
/// channel. Touch ID authorises the first call and the session covers the rest,
/// so Sesam never sees an account password and never holds a token.
///
/// **Two calls, and the expensive half is the one that runs rarely.**
/// `op item list` returns titles and vault names for everything, which is the
/// index; `op item get` returns one item's username and password, which is the
/// keystroke. Anything that fetched secrets while building the index would be
/// slower by the number of items and would put every password in this process
/// for no reason.
///
/// **`--cache` is asked for on purpose.** `op` keeps its own short lived
/// encrypted cache of item metadata, which is what makes the second and third
/// index of a session instant. It caches metadata, not secrets.
///
/// The trap: a GUI application launched from Finder inherits almost no `PATH`,
/// so `op` cannot be found by name. The three places Homebrew and the installer
/// actually put it are listed instead. A `sh -lc "op ..."` would work too and
/// would mean a login shell, that user's dotfiles, and whatever those decide to
/// do, in the process holding the passwords.
final class OnePasswordSource: Source {

    let kind = SourceKind.onePassword

    static let candidates = [
        "/opt/homebrew/bin/op",
        "/usr/local/bin/op",
        "/usr/bin/op",
    ]

    /// Guards `count`, `lastFailure` and `vaults`, written by an index on the
    /// work queue and read by the menu on the main thread.
    private let mutex = Lock()
    private var count = 0
    private var lastFailure: String?

    var state: SourceState {
        guard Shell.locate(Self.candidates) != nil else {
            return .notConfigured("op is not installed")
        }
        return mutex.around {
            if let lastFailure { return SourceState.failed(lastFailure) }
            return count == 0 ? .locked : .ready(count)
        }
    }

    func lock() {
        // Nothing is held: `op` owns the session and the desktop app owns the
        // key. Forgetting the count is all there is to forget.
        mutex.around { count = 0 }
    }

    // MARK: - the index

    struct Listed: Decodable {
        struct Vault: Decodable { let name: String? }
        struct URLEntry: Decodable { let href: String? }
        let id: String
        let title: String?
        let category: String?
        let vault: Vault?
        let urls: [URLEntry]?
        /// What `op` shows in its own list as the second line. For a login this
        /// is the username, which is exactly what the panel wants and saves an
        /// `op item get` per row.
        let additional_information: String?
    }

    /// Categories that cannot hold a password are left out, because a row that
    /// answers Command-C with nothing is worse than no row.
    static let withoutPasswords: Set<String> = [
        "SECURE_NOTE", "DOCUMENT", "IDENTITY", "MEDICAL_RECORD", "REWARD_PROGRAM",
    ]

    func index() throws -> [Item] {
        guard let op = Shell.locate(Self.candidates) else {
            throw VaultError("op is not installed.")
        }
        let result = try Shell.run(op, ["item", "list", "--cache", "--format", "json"],
                                   timeout: 90)
        guard result.ok else {
            let why = Self.explain(result.err)
            mutex.around { lastFailure = why }
            throw VaultError(why)
        }

        let items = try Self.items(fromList: result.out)
        mutex.around {
            lastFailure = nil
            count = items.count
        }
        // Asked for once, not on every index. It costs half a second, the
        // answer changes about once a year, and the only thing that reads it
        // is the new item sheet. A vault added while Sesam is running turns up
        // after the next launch, which is the right price for not paying half
        // a second every five minutes.
        if mutex.around({ vaults.isEmpty }) {
            let found = (try? Shell.run(op, ["vault", "list", "--cache", "--format", "json"], timeout: 30))
                .flatMap { $0.ok ? try? JSONDecoder().decode([Listed.Vault].self, from: $0.out) : nil }?
                .compactMap(\.name) ?? []
            mutex.around { vaults = found }
        }
        return items
    }

    /// The decode, split out from the process that produced the bytes, so the
    /// shape `op` promises can be checked in a test without an account.
    static func items(fromList data: Data) throws -> [Item] {
        try JSONDecoder().decode([Listed].self, from: data)
            .filter { !withoutPasswords.contains($0.category ?? "") }
            .map { entry in
                Item(id: entry.id,
                     title: entry.title ?? "(untitled)",
                     username: entry.additional_information,
                     url: entry.urls?.first?.href,
                     container: entry.vault?.name,
                     source: .onePassword)
            }
    }

    // MARK: - one secret

    struct Field: Decodable {
        let id: String?
        let label: String?
        let value: String?
    }

    func secret(for item: Item) throws -> Credential {
        guard let op = Shell.locate(Self.candidates) else {
            throw VaultError("op is not installed.")
        }
        var result = try Shell.run(op, ["item", "get", item.id, "--format", "json",
                                        "--fields", "label=username,label=password",
                                        "--reveal"], timeout: 60)
        guard result.ok else { throw VaultError(Self.explain(result.err)) }

        let credential = try Self.credential(fromFields: result.out)
        // That buffer held the password in the clear. Overwrite it here, the
        // same as the KeePassXC export. What cannot be overwritten is the
        // `String` the JSON decoder made on the way past, which is the ceiling
        // described in ADR 2 rather than something this line can raise.
        result.out.resetBytes(in: 0..<result.out.count)
        return credential
    }

    static func credential(fromFields data: Data) throws -> Credential {
        let fields = try JSONDecoder().decode([Field].self, from: data)
        let password = fields.first { ($0.id ?? $0.label ?? "").lowercased() == "password" }?.value
        let username = fields.first { ($0.id ?? $0.label ?? "").lowercased() == "username" }?.value

        guard let password, !password.isEmpty else {
            throw VaultError("this item has no password field", routine: true)
        }
        return Credential(username: username, password: Secret(password))
    }

    // MARK: - writing

    /// The password recipe. It is 1Password's own generator that runs, not
    /// anything here: `--generate-password` means the value is created inside
    /// the vault and never appears in an argument list, in this process, or in
    /// `ps` output. A password manager that rolled its own randomness for this
    /// would be taking on the one risk it exists to remove.
    static let recipe = "letters,digits,symbols,32"

    private var vaults: [String] = []

    var destinations: [String] { mutex.around { vaults } }

    func create(_ draft: Draft) throws -> Item {
        guard let op = Shell.locate(Self.candidates) else {
            throw VaultError("op is not installed.")
        }
        let result = try Shell.run(op, Self.createArguments(draft), timeout: 90)
        guard result.ok else { throw VaultError(Self.explain(result.err)) }

        let created = try JSONDecoder().decode(Created.self, from: result.out)
        return Item(id: created.id,
                    title: created.title ?? draft.title,
                    username: draft.username.isEmpty ? nil : draft.username,
                    url: draft.url.isEmpty ? nil : draft.url,
                    container: created.vault?.name ?? draft.destination,
                    source: .onePassword)
    }

    func regenerate(for item: Item) throws {
        guard let op = Shell.locate(Self.candidates) else {
            throw VaultError("op is not installed.")
        }
        let result = try Shell.run(op, Self.editArguments(for: item.id), timeout: 90)
        guard result.ok else { throw VaultError(Self.explain(result.err)) }
    }

    /// Built here, and tested, because the security property of this command is
    /// in its argument list: `--generate-password` and no assignment statement
    /// that carries a secret. Arguments are readable through `ps` by every
    /// process on the Mac for as long as the command runs.
    static func createArguments(_ draft: Draft) -> [String] {
        var arguments = ["item", "create", "--category", "login",
                         "--title", draft.title,
                         "--generate-password=\(recipe)",
                         "--format", "json"]
        if !draft.destination.isEmpty { arguments += ["--vault", draft.destination] }
        if !draft.url.isEmpty { arguments += ["--url", draft.url] }
        // An assignment statement, which is how `op` sets a built in field.
        // Safe here precisely because a username is not a secret; the password
        // deliberately never travels this way.
        if !draft.username.isEmpty { arguments.append("username=\(draft.username)") }
        return arguments
    }

    static func editArguments(for id: String) -> [String] {
        ["item", "edit", id, "--generate-password=\(recipe)"]
    }

    private struct Created: Decodable {
        struct Vault: Decodable { let name: String? }
        let id: String
        let title: String?
        let vault: Vault?
    }

    /// 1Password computes its own codes, over its own authenticated channel,
    /// so this asks rather than counting. It is one more subprocess on the key
    /// press, which is why it is a key of its own and not something fetched
    /// alongside every password.
    func totp(for item: Item) throws -> String {
        guard let op = Shell.locate(Self.candidates) else {
            throw VaultError("op is not installed.")
        }
        var result = try Shell.run(op, ["item", "get", item.id, "--otp"], timeout: 60)
        let code = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        result.out.resetBytes(in: 0..<result.out.count)
        guard result.ok, !code.isEmpty else {
            guard result.ok else { throw VaultError(Self.explain(result.err)) }
            throw VaultError("no one-time code in this entry", routine: true)
        }
        return code
    }

    /// `op` writes real sentences to stderr, so they are passed through rather
    /// than replaced, with the one exception that matters often enough to
    /// deserve an instruction instead of a diagnosis.
    private static func explain(_ stderr: String) -> String {
        let text = stderr.isEmpty ? "op refused, without saying why." : stderr
        if text.contains("not signed in") || text.contains("no account") {
            return "1Password is not signed in. Open the app, or run `op signin` once."
        }
        // What a Touch ID prompt that nobody answered looks like from here.
        // The word "timeout" on its own reads as a network problem, which
        // sends people to look in the wrong place entirely.
        if text.contains("authorization timeout") || text.contains("authorization prompt dismissed") {
            return "1Password asked for Touch ID and did not get it. Try again."
        }
        return text
    }
}
