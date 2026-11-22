# 2. The index is metadata, the password is fetched

Date: 2026-09-09
Status: accepted

## Context

The panel searches on every keystroke, and every keystroke touches the index.
Whatever shape that index has, it has to be cheap to build once and cheap to
scan on every character typed, across all three sources at once.

`Item`, in `Sources/Vault/Item.swift`, has an id, a title, a username, a URL
and a container. It has no password field. That is not an omission, it is the
whole security shape of the app: searching touches nothing sensitive, so the
list can be built once per unlock and kept warm, while a password is read on
the one keystroke that asks for it and let go of immediately after.

## Decision

Split every source into `index()`, which returns `[Item]` and is safe to call
often, and `secret(for:)`, which returns a `Credential` and is called exactly
once per delivery.

The Keychain source shows why this split earns its keep rather than just
looking tidy on paper. A `SecItemCopyMatching` query that asks for attributes
and not for data touches no access control list and prompts nobody; listing
every item in the login keychain this way answers in a handful of
milliseconds regardless of how many items it holds. Adding `kSecReturnData` to
that same query turns it into a request macOS itself arbitrates: the first
time Sesam asks for one item's data, the system puts up its own sheet naming
Sesam and the item, and "Always Allow" is what writes Sesam into that item's
ACL. Measured on this machine, listing 135 keychain items with attributes
alone takes about 8 milliseconds; building the index that way instead of with
`kSecReturnData` set is the only reason a search result can appear at all
before somebody has answered a sheet for every item in the keychain.

1Password is the same shape by a different mechanism. `op item list --cache`
lists titles, vaults and usernames for everything in the account; `op item
get <id> --reveal` fetches one item's username and password. Listing is the
one call that runs at launch, on a background queue, and it is measurably the
slower of the two because it has to talk to the account at all: about 3.3
seconds for 88 items in this account. Fetching one item on a keystroke is
fast because the CLI's own session is already warm by then. Building the
index by fetching every item's password would multiply that 3.3 seconds by
the size of the vault, for data nobody asked to see yet.

Passwords that do get fetched are held in a `Secret`, a byte buffer that
overwrites itself in `wipe()` and again in `deinit`. Swift strings are
immutable and copy-on-write, so a password that was ever a `String` cannot be
reliably unwritten; the runtime's own copy sits somewhere on the heap until an
allocator happens to reuse that page. `Secret` is where a password lives, not
where it has always been: see the second paragraph below.

## What this gets wrong

**Every password is a `String` before it is a `Secret`.** Both vaults answer in
a text format parsed by a string-based parser: `Foundation.XMLParser` for the
KeePassXC export, `JSONDecoder` for 1Password. So on every unlock, every
password in the KeePassXC database exists as an ordinary Swift `String` inside
`KdbxXML`, and every fetched 1Password password exists as one inside
`credential(fromFields:)`, before `Secret` ever sees it. Those copies cannot be
overwritten. The buffers that can be are: the `Data` holding the decrypted
export and the `Data` holding `op`'s JSON are both zeroed the moment they have
been parsed, and the long-lived copy is the `Secret`. Closing the rest would
mean a byte-level scanner in place of both parsers, which is a great deal of
new code between a password manager and its passwords. The ceiling is written
down here instead.

KeePassXC is the exception the split does not fully reach. Its export is all
or nothing: `unlock` decrypts the whole database in one call and every
password in it ends up held as a `Secret` in `KeePassSource.held` for as long
as that source stays unlocked. There is no per-item fetch to defer to, because
`keepassxc-cli` offers no cheaper query than the full export.

The index itself is not harmless just because it holds no passwords. A list
of every account somebody has, across three vaults, is worth something to an
attacker on its own, and it sits in process memory the whole time Sesam is
unlocked.

`Secret.withString` has to produce one real `String` on the way to
`NSPasteboard`, because that is the type the pasteboard API takes, and that
one copy is out of Sesam's hands the moment it is made. What the split buys is
not perfection, it is a short, named list of the places a password has been:
parsed bytes, one string, the pasteboard, all three eventually wiped.

The frecency file that Sesam writes to disk stores a SHA-256 hash of each
item's source and id, never the id itself, precisely because the ids
themselves would be exactly the kind of metadata this decision is trying to
keep out of anything that touches disk.

## Consequences

Every panel row exists to be looked at, not read from. A source that cannot
offer a metadata-only listing call is a source Sesam cannot support cheaply,
which is a real constraint on what gets added later.

Locking has one job per source: drop whatever `Secret` values it is holding.
For 1Password and the keychain that is nothing, because neither one ever held
a password outside the span of a single delivery. For KeePassXC it is the
`held` dictionary, which is why that source's `lock()` is the one that
actually does work.
