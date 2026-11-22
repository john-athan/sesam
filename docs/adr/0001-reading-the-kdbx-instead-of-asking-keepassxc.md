# 1. Reading the .kdbx instead of asking KeePassXC

Date: 2026-09-09
Status: accepted

## Context

KeePassXC already runs a socket for browser extensions, at
`$TMPDIR/org.keepassxc.KeePassXC.BrowserServer`. It is the obvious way in: no
new code to trust with a master password, just a protocol somebody else
already wrote a client for.

It cannot list a database. This was checked against the installed KeePassXC
2.7.12 binary rather than assumed: scanning it for the protocol's own action
strings finds `get-logins`, `associate`, `test-associate`,
`change-public-keys`, `get-databasehash`, `get-totp`, `lock-database`,
`get-database-groups` and `request-autotype`, all present. `get-database-entries`
is not there, in this version or any other the browser protocol has shipped.
`get-logins` takes a URL and returns only entries matching it. A source built
on that socket can answer "what do you have for github.com" and nothing else.
An entry with no URL, which describes most of a typical database, is invisible
to it. That is not a search bar, it is a lookup a browser extension makes on
your behalf while you sit on a page it already knows the address of.

## Decision

Read the database file directly, once per unlock.

Not with a KDBX4 reader written for Sesam. That format is Argon2id key
derivation, then AES or ChaCha20, then an HMAC block chain, then gzip, then
XML, and every one of those five steps is a place to be subtly wrong with
somebody's passwords. The binary that the format's own authors ship already
does this correctly and already sits on the Mac at
`/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli`, with
`/opt/homebrew/bin` and `/usr/local/bin` as fallbacks for a Homebrew install.

One call: `keepassxc-cli export -q -f xml <database>`, with `-k <keyfile>`
appended when a key file is configured. The master password goes to the child
process on stdin, appended with a newline, and is never a command-line
argument, because arguments sit in `ps` output for the life of the process and
stdin does not. `Shell.run` writes it, closes the pipe, and the caller wipes
its own copy the moment the call returns.

There is no long-lived child process holding an unlocked database open.
`keepassxc-cli` runs, prints the whole export once, and exits. The export
arrives as XML on a pipe, is parsed by `KdbxXML.swift` using Foundation's
`XMLParser`, and the `Data` buffer holding it is overwritten in place as soon
as the parser has consumed it, before it goes out of scope.

## What this gets wrong

Sesam's own lock has nothing to do with KeePassXC's. The two apps hold two
separate copies of the same secrets, unlocked independently, so a KeePassXC
that has locked itself in the meantime does not lock Sesam, and there is no
signal in the other direction either.

The index goes stale the moment somebody edits the database in KeePassXC and
does not tell Sesam. Nothing here watches the file; the fix is to unlock
again, which re-exports and rebuilds.

YubiKey-protected databases do not work. `keepassxc-cli export` accepts a `-y`
flag for a hardware key and Sesam never passes it, only `-k` for a key file.
TOTP secrets, file attachments and custom string fields are read straight past
by the parser, which keeps only title, username, URL and password out of
every entry's field bag.

All of this depends on somebody else's binary being installed at all, and on
`export -f xml` continuing to mean what it means today. A future KeePassXC
that changes the export schema breaks Sesam silently until somebody notices
the field names moved.

## Consequences

Every unlock is a full re-export and re-parse, proportional to database size,
not an incremental read. For a database in the low thousands of entries that
is milliseconds, which is why there is no attempt to cache the XML itself
across launches.

Adding support for a second file-based format later means teaching `Shell` a
different CLI invocation, not writing a second parser, as long as that
format's own tooling can also export to a structured text format on stdout.

Reading the whole database means Sesam necessarily holds every one of its
passwords in memory for as long as it stays unlocked, which is the subject of
the next decision.
