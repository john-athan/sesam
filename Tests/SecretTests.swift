import Foundation

/// The promises made about passwords in memory, on the clipboard, and on disk.
func runSecretTests() {

    Check.suite("a secret can be taken back") {
        let secret = Secret("hunter2")
        Check.equal(secret.withString { $0 }, "hunter2", "it reads back before it is wiped")
        secret.wipe()
        Check.that(secret.isEmpty, "and it is empty afterwards")
        Check.equal(secret.withString { $0 }, "", "with nothing left to read")
        secret.wipe()
        Check.that(secret.isEmpty, "wiping twice is allowed")
    }

    Check.suite("the clipboard is only taken back if it is still ours") {
        Check.that(Deliver.shouldClear(written: 12, now: 12),
                   "nobody has written since, so the password is cleared")
        Check.that(!Deliver.shouldClear(written: 12, now: 13),
                   "somebody copied something else, so their clipboard is left alone")
    }

    Check.suite("the usage file cannot be read") {
        // An explicit salt, so the suite neither reads nor creates the real
        // one, which lives in the login keychain.
        let salt = Data(repeating: 7, count: 32)
        let key = "1password/abc123"
        let hashed = Frecency.hash(key, salt: salt)
        Check.equal(hashed.count, 64, "keys on disk are SHA-256, written out in hex")
        Check.that(!hashed.contains("abc"), "the item id is not in the file")
        Check.equal(Frecency.hash(key, salt: salt), hashed,
                    "and the same key always hashes the same")
        Check.that(Frecency.hash("keychain/abc123", salt: salt) != hashed,
                   "two sources with the same id are two different items")
        Check.that(Frecency.hash(key, salt: Data(repeating: 8, count: 32)) != hashed,
                   "a different salt is a different file, so a wordlist from one "
                   + "machine is worthless against another")
    }

    Check.suite("an item carries no secret") {
        let item = Item(id: "x", title: "GitHub", username: "john", url: nil,
                        container: "Personal", source: .onePassword)
        Check.equal(item.key, "1password/x", "the frecency key names the source")
        Check.that(!"\(item)".lowercased().contains("password:"),
                   "there is no password field to print by accident")
    }
}

/// The keychain item id has one job: survive a rebuild of the index, so that
/// the frecency counts and the fetch both still find the item they mean.
func runKeychainAddressTests() {

    Check.suite("an item id addresses an item") {
        let id = KeychainSource.address("genp", "gh:github.com", "ada-lovelace")
        guard let parsed = Check.unwrap(KeychainSource.parse(id), "it parses back") else { return }
        Check.equal(parsed.itemClass, "genp", "the class survives")
        Check.equal(parsed.service, "gh:github.com", "so does the service, colons and all")
        Check.equal(parsed.account, "ada-lovelace", "and the account")
        Check.equal(KeychainSource.address("genp", "gh:github.com", "ada-lovelace"), id,
                    "the same item is the same id every time, so counts are not lost")
    }

    Check.suite("an item with no account") {
        guard let parsed = Check.unwrap(KeychainSource.parse(KeychainSource.address("inet", "example.com", "")),
                                        "an empty account is still addressable") else { return }
        Check.equal(parsed.account, "", "and reads back as empty rather than missing")
    }

    Check.suite("nonsense is refused rather than guessed at") {
        Check.isNil(KeychainSource.parse("1password/abc"), "another source's id is not a keychain id")
        Check.isNil(KeychainSource.parse(""), "nor is nothing")
        Check.isNil(KeychainSource.parse("cert\u{1F}a\u{1F}b"), "nor a class Sesam does not read")
    }
}
