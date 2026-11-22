import Foundation
import Security
import LocalAuthentication

/// The finger instead of the phrase. 👆
///
/// A KeePassXC master password is long on purpose, and Sesam locks itself every
/// fifteen minutes on purpose, and those two purposes are in a fight. This is
/// the settlement, and it is off by default: with "Remember its password"
/// switched on, the master password is kept in the login keychain and a
/// fingerprint is asked for before it is read back.
///
/// **What this is not.** The strong version of this feature puts the password
/// in the data protection keychain under
/// `kSecAccessControlBiometryCurrentSet`, where the Secure Enclave itself
/// refuses to unwrap it without a fingerprint and enrolling a new finger
/// destroys it. That needs an `application-identifier` entitlement, which needs
/// a Developer ID signature. Sesam is ad-hoc signed and built from source: the
/// add fails with `errSecMissingEntitlement`, and a binary signed with the
/// entitlement anyway is killed on launch. Both were tried.
///
/// So this is the weaker version, and it is worth being exact about what it
/// buys. It stops somebody who walks up to an unlocked Mac, because the
/// fingerprint sheet is in the way. It does not stop somebody who can run their
/// own code as you: the check is in this process, and the item is readable by
/// this code identity without it. If that is in your threat model, leave the
/// switch off and type the master password. The default is off for that reason.
enum TouchID {

    private static let service = "io.github.john-athan.sesam"
    private static let account = "keepass-master"

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Whether the user asked Sesam to remember the master password. Separate
    /// from whether one is stored: the switch can be on before the next
    /// successful unlock puts anything there.
    static var isWanted: Bool {
        get { UserDefaults.standard.bool(forKey: "rememberKeePass") }
        set {
            UserDefaults.standard.set(newValue, forKey: "rememberKeePass")
            if !newValue { forget() }
        }
    }

    /// Store, replacing whatever was there. Returns nil on success, or a
    /// message for the user.
    static func remember(_ password: [UInt8]) -> String? {
        forget()
        var query = base
        query[kSecValueData] = Data(password)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrDescription] = "Sesam: KeePassXC master password"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status != errSecSuccess else { return nil }
        return SecCopyErrorMessageString(status, nil) as String? ?? "keychain error \(status)"
    }

    /// Ask for a fingerprint, then read it back. Returns nil when there is
    /// nothing stored, or when the check was refused: both mean "ask for the
    /// password instead", and neither is worth an alert.
    static func recall(reason: String) -> [UInt8]? {
        guard isWanted, check(reason: reason) else { return nil }
        var query = base
        query[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return [UInt8](data)
    }

    static func forget() {
        SecItemDelete(base as CFDictionary)
    }

    /// The biometric check, made to look synchronous.
    ///
    /// The trap: `evaluatePolicy` returns at once and calls back later, so this
    /// blocks the caller on a semaphore. That is safe here and would not be
    /// safe everywhere: the reply runs on a queue private to LocalAuthentication
    /// and never on the main queue, and the sheet itself is drawn by another
    /// process, so a blocked main thread does not stop the user answering it.
    /// The timeout is there so that a sheet nobody ever answers cannot wedge
    /// the app for good.
    private static func check(reason: String) -> Bool {
        let context = LAContext()
        var granted = false
        let done = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: reason) { success, _ in
            granted = success
            done.signal()
        }
        guard done.wait(timeout: .now() + 60) == .success else { return false }
        return granted
    }

    private static var base: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
