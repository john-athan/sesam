import Foundation
import Security

/// The keychain, read as a guest. 🍎
///
/// The only source that needs no other program and no password of its own,
/// because macOS is already holding the key: the login keychain is unlocked
/// when you log in.
///
/// **Listing is free, reading is not.** A `SecItemCopyMatching` that asks for
/// attributes and not for data touches no access control list, prompts nobody,
/// and returns in a few milliseconds. Adding `kSecReturnData` to the same query
/// turns it into a request that the system arbitrates: the first time Sesam
/// reads a given item, macOS puts up its own sheet naming Sesam and that item,
/// and "Always Allow" writes Sesam into that item's ACL. That split is why the
/// index and the fetch are two different queries here rather than one.
///
/// **What is not here, and cannot be.** Passwords saved by Safari and shown in
/// the Passwords app live in the iCloud keychain behind an entitlement Apple
/// does not issue to third parties. They are invisible to this code, not
/// filtered out by it. The menu says so, because the alternative is a user
/// concluding Sesam is broken.
///
/// The trap: the item id has to survive a rebuild of the index, or the
/// frecency counts would reset every refresh. So it is derived from the
/// attributes that identify the item (class, service or server, account)
/// rather than being a row number or a fresh UUID. An item whose service name
/// contains U+001F would decode wrong; nothing in a real keychain does.
final class KeychainSource: Source {

    let kind = SourceKind.keychain
    private let mutex = Lock()
    private var found = 0

    /// Read from the main thread while an index may be running on another, so
    /// the count behind it is guarded like every other source's.
    var state: SourceState { mutex.around { found == 0 ? .locked : .ready(found) } }

    private static let sep = "\u{1F}"

    /// The two halves of the item id, kept next to each other so they cannot
    /// drift apart. `genp` and `inet` are the keychain's own names for the two
    /// classes, so the id says what it addresses.
    static func address(_ itemClass: String, _ service: String, _ account: String) -> String {
        [itemClass, service, account].joined(separator: sep)
    }

    static func parse(_ id: String) -> (itemClass: String, service: String, account: String)? {
        let parts = id.components(separatedBy: sep)
        guard parts.count == 3, parts[0] == "genp" || parts[0] == "inet" else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    func lock() { /* macOS holds this key, not Sesam. Nothing to let go of. */ }

    func index() throws -> [Item] {
        var items = query(kSecClassGenericPassword).compactMap(generic)
        items += query(kSecClassInternetPassword).compactMap(internet)
        mutex.around { found = items.count }
        return items
    }

    func secret(for item: Item) throws -> Credential {
        guard let (itemClass, service, account) = Self.parse(item.id) else {
            throw VaultError("that keychain item cannot be addressed.")
        }

        var q: [CFString: Any] = [
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        if itemClass == "genp" {
            q[kSecClass] = kSecClassGenericPassword
            q[kSecAttrService] = service
        } else {
            q[kSecClass] = kSecClassInternetPassword
            q[kSecAttrServer] = service
        }
        if !account.isEmpty { q[kSecAttrAccount] = account }

        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { throw VaultError("that item holds no password.") }
            return Credential(username: account.isEmpty ? nil : account,
                              password: Secret([UInt8](data)))
        case errSecUserCanceled, errSecAuthFailed:
            throw VaultError("the keychain refused: you did not allow Sesam to read that item.")
        case errSecItemNotFound:
            throw VaultError("that item is no longer in the keychain. Rebuild the index.")
        default:
            let why = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw VaultError("the keychain refused: \(why)")
        }
    }

    // MARK: - reading the shelf

    private func query(_ itemClass: CFString) -> [[CFString: Any]] {
        let q: [CFString: Any] = [
            kSecClass: itemClass,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[CFString: Any]] else { return [] }
        return rows
    }

    private func generic(_ row: [CFString: Any]) -> Item? {
        guard let service = row[kSecAttrService] as? String, !service.isEmpty else { return nil }
        // The login keychain is mostly machinery: iCloud tokens, proxy tokens,
        // assistant state. None of it is a password anybody pastes, and there
        // are more of them than there are real logins, so they are left out.
        guard !service.hasPrefix("com.apple.") else { return nil }
        let account = row[kSecAttrAccount] as? String ?? ""
        return Item(id: Self.address("genp", service, account),
                    title: row[kSecAttrLabel] as? String ?? service,
                    username: account.isEmpty ? nil : account,
                    url: nil,
                    container: "Keychain",
                    source: .keychain)
    }

    private func internet(_ row: [CFString: Any]) -> Item? {
        guard let server = row[kSecAttrServer] as? String, !server.isEmpty else { return nil }
        let account = row[kSecAttrAccount] as? String ?? ""
        return Item(id: Self.address("inet", server, account),
                    title: row[kSecAttrLabel] as? String ?? server,
                    username: account.isEmpty ? nil : account,
                    url: "https://" + server,
                    container: "Keychain",
                    source: .keychain)
    }
}
