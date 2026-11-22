import Foundation
import CryptoKit

/// The six digits. ⏱️
///
/// RFC 6238, which is RFC 4226 counting in thirty second steps: HMAC the
/// counter with the shared secret, take four bytes from an offset the last
/// nibble of the digest points at, and print the low digits.
///
/// This exists because the two vaults answer the question differently and only
/// one of them can be asked. 1Password computes the code itself, over its own
/// authenticated channel, and `op item get --otp` prints it. KeePassXC will
/// compute one too, but only through `keepassxc-cli show -t`, which wants the
/// master password again and pays for Argon2id every time it is asked. Sesam
/// already has the seed from the export it did at unlock, so it counts the
/// digits itself.
///
/// **The seed is treated like a password, because it is one.** Anybody holding
/// it can mint codes forever. It lives in a `Secret` alongside the entry's
/// password and is wiped by the same `lock()`.
///
/// The trap: base32, not base64, and KeePassXC writes it both bare and wrapped
/// in an `otpauth://` URI depending on how the entry was made. Both shapes are
/// read here. A seed with lowercase letters, spaces or missing padding is
/// still a valid seed and is normalised rather than rejected, because every
/// one of those turns up in real databases.
enum TOTP {

    /// Everything an entry can say about its one-time codes.
    struct Settings {
        var secret: [UInt8]
        var digits = 6
        var period = 30
        var algorithm = Algorithm.sha1

        enum Algorithm: String { case sha1, sha256, sha512 }
    }

    /// The code for a given moment. `at` is a parameter so the RFC's own test
    /// vectors can be checked rather than trusted.
    static func code(_ settings: Settings, at time: Date = Date()) -> String {
        let counter = UInt64(time.timeIntervalSince1970) / UInt64(max(1, settings.period))
        var big = counter.bigEndian
        let message = withUnsafeBytes(of: &big) { Data($0) }
        let key = SymmetricKey(data: Data(settings.secret))

        let digest: [UInt8]
        switch settings.algorithm {
        case .sha1:   digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: digest = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: digest = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        let offset = Int(digest[digest.count - 1] & 0x0F)
        let truncated = (UInt32(digest[offset] & 0x7F) << 24)
                      | (UInt32(digest[offset + 1]) << 16)
                      | (UInt32(digest[offset + 2]) << 8)
                      |  UInt32(digest[offset + 3])
        let digits = min(max(settings.digits, 6), 10)
        // 10^10 does not fit in 32 bits, and an otpauth URI can ask for ten
        // digits: the conversion traps, so the arithmetic is 64 bit.
        let modulus = UInt64(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)llu", UInt64(truncated) % modulus)
    }

    /// Seconds left on the current code, for the panel to show.
    static func remaining(_ settings: Settings, at time: Date = Date()) -> Int {
        let period = max(1, settings.period)
        return period - Int(time.timeIntervalSince1970) % period
    }

    /// Read whatever the entry had in it. Accepts a bare base32 seed, an
    /// `otpauth://totp/...?secret=...` URI, or nil when there is nothing.
    static func settings(from field: String) -> Settings? {
        let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        guard text.lowercased().hasPrefix("otpauth://") else {
            guard let secret = base32(text) else { return nil }
            return Settings(secret: secret)
        }

        guard let components = URLComponents(string: text) else { return nil }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name.lowercased() == name }?.value
        }
        guard let raw = value("secret"), let secret = base32(raw) else { return nil }

        var settings = Settings(secret: secret)
        if let digits = value("digits").flatMap(Int.init) { settings.digits = digits }
        if let period = value("period").flatMap(Int.init) { settings.period = period }
        if let name = value("algorithm")?.lowercased(),
           let algorithm = Settings.Algorithm(rawValue: name) {
            settings.algorithm = algorithm
        }
        return settings
    }

    /// RFC 4648 base32, forgiving: case is ignored, and padding, spaces and
    /// dashes are dropped rather than refused.
    static func base32(_ text: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, accumulator = 0
        var out: [UInt8] = []
        for character in text.uppercased() {
            if character == "=" || character == " " || character == "-" { continue }
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        return out.isEmpty ? nil : out
    }
}
