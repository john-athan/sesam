# 7. One-time codes are counted here for KeePassXC and asked for from 1Password

Date: 2026-09-09
Status: accepted

## Context

Most logins that matter have a second factor sitting next to the password,
and Command-T copies its current code the same way Command-C copies the
password. The two vaults answer "what is the code right now" in completely
different ways, and only one of them can be asked cheaply on every key
press.

## Decision

For 1Password, Sesam asks: `op item get <id> --otp` computes the code inside
1Password, over its own authenticated channel, and Sesam only reads the
answer back. For KeePassXC, Sesam is not asked, it counts. `keepassxc-cli
show -t` would compute one too, but it wants the master password again and
pays for Argon2id on every single press of Command-T. The seed already
arrived with the rest of the entry during the export KeePassXC did at
unlock, so `Sources/Vault/TOTP.swift` counts the digits itself rather than
spending a subprocess and a key derivation on a number it already has the
ingredients for.

`TOTP.swift` is RFC 6238 over CryptoKit's HMAC: HMAC the time step with the
shared secret, take four bytes from an offset the digest's own last nibble
points at, print the low digits. SHA-1, SHA-256 and SHA-512 are all
supported because the RFC allows all three, and a base32 decoder tolerates
lowercase letters, spaces and missing padding because all three turn up in
real databases rather than only in the RFC's own clean examples. Checked
against RFC 6238 appendix B's own test vectors in `Tests/TOTPTests.swift`,
which is the point at which a wrong implementation would otherwise look
identical to a right one that is merely running against the wrong clock.

Two storage conventions get normalised in the parser rather than carried
downstream as two shapes. KeePassXC's own editor writes a field called `otp`
holding a whole `otpauth://` URI. Databases that came from KeeWeb or from
the KeeOtp plugin instead carry a bare base32 seed in `TOTP Seed` and a
`period;digits` pair in `TOTP Settings`. `KdbxXML.otp` rebuilds the second
shape into the first, so `TOTP.settings(from:)` and everything above it only
ever has one format to read.

The seed itself is held in a `Secret`, the same type the password uses, and
wiped by the same `lock()`. Anybody holding a seed can mint codes for as
long as the seed is valid, which in practice is forever: it is a password
with a longer life, not a lightweight extra.

## What this gets wrong

A Mac with a wrong clock produces wrong codes on the KeePassXC side, and
that looks exactly like a vault problem to whoever is staring at it, not
like the clock problem it actually is. SHA-1 stays the default algorithm
because that is what authenticator apps in the wild actually use, not
because it is the strongest of the three CryptoKit offers.

The code is copied to the clipboard rather than shown with a countdown, so a
code copied in the last second of its thirty second window can be stale by
the time it lands in a paste. The login keychain has no notion of a second
factor at all, and nothing here changes that. 1Password's route costs a
subprocess on every key press, about a second when its own session is
already warm and a Touch ID prompt when it is not, where KeePassXC's local
count is close to free once the seed is in hand. Non-standard codes, Steam's
own alphabet in particular, are not supported by either path.

## Consequences

Adding a fourth vault means answering the same question this one did before
writing a line of TOTP code for it: does the vault already compute its own
codes over a channel Sesam can just ask through, or does Sesam have to hold
the seed and count. The two existing vaults sit on opposite sides of that
line, which is why the decision reads as two decisions rather than one.

`Tests/TOTPTests.swift` is what makes changing the offset math or the base32
decoder safe: a wrong nibble or a padding rule that got stricter fails a
known vector immediately, before it reaches a real code that would otherwise
just look thirty seconds late.
</content>
