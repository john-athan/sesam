import Foundation

/// RFC 6238's own test vectors, and the two shapes a seed arrives in. ⏱️
///
/// The vectors matter more than usual here: a one-time code that is wrong is
/// indistinguishable from a one-time code that is merely late, so a broken
/// implementation looks like a clock problem and gets debugged in the wrong
/// place for an hour.
func runTOTPTests() {

    // The RFC's shared secret is the ASCII string "12345678901234567890".
    let seed = Array("12345678901234567890".utf8)
    let rfc = TOTP.Settings(secret: seed, digits: 8, period: 30, algorithm: .sha1)

    Check.suite("RFC 6238, appendix B") {
        let vectors: [(TimeInterval, String)] = [
            (59, "94287082"),
            (1111111109, "07081804"),
            (1111111111, "14050471"),
            (1234567890, "89005924"),
            (2000000000, "69279037"),
            (20000000000, "65353130"),
        ]
        for (seconds, expected) in vectors {
            Check.equal(TOTP.code(rfc, at: Date(timeIntervalSince1970: seconds)), expected,
                        "SHA-1 at t=\(Int(seconds))")
        }
    }

    Check.suite("six digits is the default, and the common case") {
        let six = TOTP.Settings(secret: seed)
        let code = TOTP.code(six, at: Date(timeIntervalSince1970: 59))
        Check.equal(code.count, 6, "six digits")
        Check.equal(code, "287082", "which are the last six of the eight digit vector")
    }

    Check.suite("digit counts at the edges of what a URI can ask for") {
        for digits in [1, 9, 10, 99] {
            let settings = TOTP.Settings(secret: seed, digits: digits)
            let want = min(max(digits, 6), 10)
            Check.equal(TOTP.code(settings, at: Date(timeIntervalSince1970: 59)).count, want,
                        "\(digits) digits asked for, \(want) given")
        }
    }

    Check.suite("the clock") {
        let settings = TOTP.Settings(secret: seed)
        Check.equal(TOTP.remaining(settings, at: Date(timeIntervalSince1970: 0)), 30,
                    "a fresh period has all of it left")
        Check.equal(TOTP.remaining(settings, at: Date(timeIntervalSince1970: 29)), 1,
                    "and one second at the end")
        Check.equal(TOTP.code(settings, at: Date(timeIntervalSince1970: 59)),
                    TOTP.code(settings, at: Date(timeIntervalSince1970: 30)),
                    "the code does not change inside a period")
        Check.that(TOTP.code(settings, at: Date(timeIntervalSince1970: 59))
                != TOTP.code(settings, at: Date(timeIntervalSince1970: 60)),
                   "and does change at the boundary")
    }

    Check.suite("base32, as it turns up in real databases") {
        Check.equal(TOTP.base32("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ").map { String(decoding: $0, as: UTF8.self) },
                    "12345678901234567890", "the RFC's seed, encoded")
        Check.equal(TOTP.base32("gezdgnbv"), TOTP.base32("GEZDGNBV"), "case is ignored")
        Check.equal(TOTP.base32("GEZD GNBV"), TOTP.base32("GEZDGNBV"), "spaces are ignored")
        Check.equal(TOTP.base32("GEZDGNBV===="), TOTP.base32("GEZDGNBV"), "so is padding")
        Check.isNil(TOTP.base32("not-base-32-at-all!"), "and nonsense is refused")
        Check.isNil(TOTP.base32(""), "as is nothing")
    }

    Check.suite("the two shapes an entry stores") {
        guard let bare = Check.unwrap(TOTP.settings(from: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
                                      "a bare seed is a seed") else { return }
        Check.equal(TOTP.code(bare, at: Date(timeIntervalSince1970: 59)), "287082",
                    "and produces the RFC's code")

        let uri = "otpauth://totp/Example:alice@example.com"
                + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example&digits=8&period=60"
        guard let parsed = Check.unwrap(TOTP.settings(from: uri), "a URI parses") else { return }
        Check.equal(parsed.digits, 8, "digits come from the query")
        Check.equal(parsed.period, 60, "so does the period")
        Check.equal(parsed.secret, seed, "and the secret is decoded")

        Check.isNil(TOTP.settings(from: ""), "an empty field is not a code")
        Check.isNil(TOTP.settings(from: "otpauth://totp/x?issuer=y"), "nor is a URI with no secret")
    }
}
