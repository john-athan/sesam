import Foundation
import CryptoKit
import Security

/// The memory of what you actually use. 📈
///
/// A count per item, so the thing you copy every morning is the first row
/// before you have typed anything. This is the only file Sesam writes.
///
/// **It cannot be read.** The key on disk is a SHA-256 of the item's source and
/// id, never the id itself, so the file is a list of hashes and integers: it
/// says somebody used something eleven times and cannot say what. That matters
/// because the interesting half of a password is often the fact that you have
/// an account at all, and a plain list of vault entry names sitting in
/// Application Support gives that away to anything that can read your home
/// directory.
///
/// Written with `0600` on a file the process creates itself, and small enough
/// (a few kilobytes) that it is rewritten whole rather than appended to.
///
/// The trap: hashing the id means a renamed entry keeps its count only if its
/// id is stable. That is why `Item.id` is derived from the vault's own
/// identifier where there is one, and from the addressing attributes where
/// there is not (see `KeychainSource`).
enum Frecency {

    private static var counts: [String: Int] = load()

    static func count(for key: String) -> Int { counts[hash(key)] ?? 0 }

    /// Record a use. Called when a password or username is actually delivered,
    /// not when a row is merely looked at.
    static func used(_ key: String) {
        counts[hash(key), default: 0] += 1
        save()
    }

    static func forget() {
        counts = [:]
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - the file

    static var file: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sesam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("frecency.json")
    }

    static func hash(_ key: String) -> String { hash(key, salt: salt) }

    /// Salted, and the salt is not in the file.
    ///
    /// A bare SHA-256 of "1password/GitHub" is not a secret: anybody holding
    /// `frecency.json` can hash a wordlist of service names against it and
    /// learn which accounts exist, which is most of what the hashing was
    /// supposed to hide. The file is `0600`, so this only matters where the
    /// file travels without its owner: a backup, a synced folder, a disk handed
    /// on. A random salt in the login keychain travels with neither.
    static func hash(_ key: String, salt: Data) -> String {
        var input = salt
        input.append(Data(key.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// Read once, created on first use, and never written to disk by Sesam.
    private static let salt: Data = {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "io.github.john-athan.sesam",
            kSecAttrAccount: "frecency-salt",
        ]
        var out: CFTypeRef?
        var read = query
        read[kSecReturnData] = true
        if SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess,
           let existing = out as? Data, existing.count == 32 {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Without randomness the counts are still counts; they are just
            // back to being guessable, which is where they started.
            return Data()
        }
        let fresh = Data(bytes)
        var add = query
        add[kSecValueData] = fresh
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrDescription] = "Sesam: salt for the usage counts"
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }()

    private static func load() -> [String: Int] {
        guard let data = try? Data(contentsOf: file),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return counts
    }

    private static func save() {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
