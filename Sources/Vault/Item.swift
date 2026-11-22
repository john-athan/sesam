import Foundation

/// What a vault is willing to say out loud. 🏷️
///
/// One record type for all three sources, and it holds no secret. A 1Password
/// login, a KeePassXC entry and a keychain item differ in almost everything
/// except the four things the panel draws, so those four are what crosses the
/// boundary: a title, maybe a username, maybe a URL, and the name of whatever
/// the source calls a container.
///
/// **The index is metadata, the password is fetched.** This is the whole
/// security shape of the app in one sentence. Searching touches nothing
/// sensitive, so the list can be built once and kept warm; a password is read
/// on the keystroke that asks for it and let go of immediately afterwards.
/// That is why `Item` has no password field to forget to clear.
struct Item: Equatable {

    /// Opaque, and only the source that made it knows what it means: a
    /// 1Password item id, a KeePassXC entry path, a keychain service name.
    let id: String
    let title: String
    let username: String?
    let url: String?
    /// The 1Password vault, the KeePassXC group, or the keychain's own name.
    let container: String?
    let source: SourceKind

    /// The key everything outside the vault uses to remember this item without
    /// remembering anything about it. Two sources could hand out the same id,
    /// so the source is part of the key.
    var key: String { "\(source.rawValue)/\(id)" }

    /// A row that does something to Sesam rather than handing over a password.
    /// There is exactly one, and it exists so that a locked KeePassXC can be
    /// opened from the panel instead of from the menu bar: Option-Space is
    /// meant to be the whole interface, and a source you can only unlock with
    /// the mouse breaks that promise on the first search of every day.
    static let unlockKeePass = Item(
        id: "sesam:unlock-keepass",
        title: "Unlock KeePassXC",
        username: "its entries appear here once it is open",
        url: nil, container: nil, source: .keePass)

    var isAction: Bool { id.hasPrefix("sesam:") }
}

enum SourceKind: String, CaseIterable {
    case onePassword = "1password"
    case keePass     = "keepassxc"
    case keychain    = "keychain"

    var label: String {
        switch self {
        case .onePassword: return "1Password"
        case .keePass:     return "KeePassXC"
        case .keychain:    return "Keychain"
        }
    }

    /// One letter for the badge at the right of a result row.
    var badge: String {
        switch self {
        case .onePassword: return "1P"
        case .keePass:     return "KP"
        case .keychain:    return "K"
        }
    }
}

/// A password, for as long as it takes to deliver it. 🤫
///
/// A byte buffer that zeroes itself, rather than a `String`. Swift strings are
/// immutable, copy on write and heap allocated, so a password that has been a
/// `String` cannot be unwritten: the copy the runtime made is somewhere in the
/// heap until an allocator reuses that page. Bytes can be overwritten, so the
/// password is bytes for the whole of its life inside Sesam.
///
/// **The trap, stated rather than hidden:** the last step out of Sesam is
/// `NSPasteboard`, and that takes a `String`. `withString` therefore makes
/// exactly one, hands it to the caller, and that copy is out of our hands. What
/// this buys is not perfection, it is a much shorter list of places a password
/// has been: parsed bytes, wiped; one string, briefly; the pasteboard, wiped on
/// a timer. Not: the search index, not the frecency file, not a log, not disk.
final class Secret {

    private var bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// From a string that already exists (a subprocess wrote it into one on the
    /// way in). The string is not ours to wipe; the copy made here is.
    convenience init(_ text: String) { self.init(Array(text.utf8)) }

    var isEmpty: Bool { bytes.isEmpty }

    /// Materialise the password for one call, and no longer.
    func withString<T>(_ body: (String) -> T) -> T {
        body(String(decoding: bytes, as: UTF8.self))
    }

    /// Overwrite the buffer. Idempotent, and called from `deinit` as well as by
    /// hand, because the two moments a password should disappear are "the vault
    /// locked" and "nobody is holding this any more".
    func wipe() {
        for i in bytes.indices { bytes[i] = 0 }
        bytes.removeAll(keepingCapacity: false)
    }

    deinit { wipe() }
}

/// What a source hands back when asked for one item's secrets.
struct Credential {
    let username: String?
    let password: Secret
}
