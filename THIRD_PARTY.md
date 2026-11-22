# Third-party material in Sesam

Sesam is MIT licensed. This file records anything in the repository that
originated elsewhere, and anything Sesam depends on at runtime that it does not
ship, so an attribution obligation cannot hide in the gap between "we wrote it"
and "nobody checked".

## Dependencies

None, and there is no manifest that could acquire one. `tools/build-app.sh` gathers every
`.swift` file under `Sources/` and hands the list to `swiftc`; there is no
`Package.swift`, no Xcode project and no package manager. The app links Apple's
SDK frameworks only (Cocoa, Carbon, Security, ServiceManagement,
LocalAuthentication, and CryptoKit through the standard library), which are used
under the Apple Developer Program agreement and are not redistributed here.

## Programs Sesam runs, and does not ship

This is the part that makes Sesam different from the other projects here: two of
its three sources are other people's binaries, started as child processes. Both
are installed by the user, neither is bundled, linked, embedded or
redistributed, and neither one's code is compiled into the Sesam binary.

### `keepassxc-cli`, from KeePassXC (GPL-3.0)

Sesam runs the `keepassxc-cli` that ships inside KeePassXC.app, or the one
Homebrew installs, to read a `.kdbx` file. It starts it as a child process with
an argument list and a password on stdin, the way a shell script would, and
reads its standard output. ADR 1 explains why that route exists at all: the
browser socket cannot list a database.

What that means for the licence, stated as fact rather than as advice: no
GPL-3.0 code is copied into this repository, linked into the binary, or
distributed with it. A user who has not installed KeePassXC has no
`keepassxc-cli`, and Sesam says so and carries on with its other two sources.
Removing KeePassXC removes the dependency completely, which is the test that
matters here.

### `op`, the 1Password CLI (proprietary)

Sesam runs `op` to list items and to fetch one item's fields. It is installed
separately (`brew install 1password-cli`), it is not bundled or redistributed,
and its own licence terms are a matter between its user and AgileBits. Sesam's
MIT licence covers Sesam and extends over nothing else.

This is a runtime dependency on proprietary software, and it is worth being
plain about it: the 1Password source does not work without a program whose
source nobody here can read. That is the price of talking to 1Password at all,
and it is why the other two sources do not go through it.

## Bundled assets

`assets/panel.png` is drawn by Sesam's own drawing code, from invented entries,
by a small program that links `Sources/Panel/*.swift`. It is not a screenshot of
anybody's vault.

The menu bar glyph is an SF Symbol, drawn from the system at runtime. SF Symbols
are licensed by Apple for use in software running on Apple platforms and may not
be redistributed as artwork. No symbol is exported into this repository.

## Reviewed and cleared

What follows is the author's own assessment and not legal advice.

### RFC 6238, and the one-time code arithmetic (2026-09-09)

`Sources/Vault/TOTP.swift` implements TOTP from the RFC text: the counter, the
HMAC, the dynamic truncation and the base32 alphabet are all specified there,
and the test vectors in `Tests/TOTPTests.swift` are the ones printed in the
RFC's own appendix B. No implementation was copied. RFC 6238 is an IETF
document; its test vectors are published as part of the specification for
exactly this purpose.

### The KDBX XML shape (2026-09-09)

`Sources/Vault/KdbxXML.swift` reads the XML that `keepassxc-cli export -f xml`
prints. The element names it looks for were established by inspecting the
output of that command on a database created for the purpose, not by reading
KeePassXC's source. The knowledge that history entries nest inside an entry and
that the recycle bin is identified by a UUID in `Meta` is a fact about a file
format, recorded here so the next reader does not have to rediscover it.
