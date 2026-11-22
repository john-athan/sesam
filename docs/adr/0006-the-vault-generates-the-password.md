# 6. The vault generates the password, and Sesam never sees a new one being made

Date: 2026-09-09
Status: accepted

## Context

Sesam has been read only since the first line of it: an index built from a
vault, a password fetched from a vault, nothing sent back. Two requests kept
coming up anyway, saving a new login while it is being made up on the spot,
and rotating a password on a site that just asked for one, and both need
Sesam to write. The question is not whether to write, it is who gets to
decide what the new password is.

## Decision

Sesam can now write, in exactly two ways: create a login, and replace an
existing entry's password. No rename, no delete, no notes, no tags, no
category choice. Neither path invents a password.

For 1Password, creating a login runs
`op item create --category login --title T --generate-password=letters,digits,symbols,32 --format json`,
with `--vault` and `--url` added when the sheet's fields were filled in, and a
`username=` assignment for the same reason: a username is not a secret.
Replacing a password runs `op item edit <id> --generate-password=...` against
the same recipe. For KeePassXC, the equivalent commands are
`keepassxc-cli add -q -g -L 30 -l -U -n -s` and `keepassxc-cli edit -q -g -L 30
-l -U -n -s`, thirty characters because that matches KeePassXC's own
configured default rather than a number chosen here.

Two reasons sit behind `--generate-password` and `-g` rather than a value
Sesam made up and passed in. First, an argument list is world readable
through `ps` for as long as the command runs, so a password passed as an
argument is a password handed to anything watching the process table at the
right moment; `op`'s own documentation says to use a template file for
sensitive values for exactly this reason, and a temporary file holding a
plaintext password on disk is worse than the problem it would solve. Second,
a password manager should not ship its own random number generator when the
two vaults it talks to already have audited ones doing that job.

The argument builders, `OnePasswordSource.createArguments`, `editArguments`,
and `KeePassSource.addArguments`, `editArguments`, `path`, are pure static
functions returning `[String]`, built that way so `Tests/WriteTests.swift`
can assert the security property directly: `--generate-password` or `-g` is
present, and nothing in the list is an assignment statement carrying a
secret. Verified beyond the tests too: `op item create --dry-run` returns an
item with an id, a title, a vault, and a 32 character password field, which
is what `Created` decodes; a throwaway KeePassXC database took a create and a
regenerate in turn, producing a 30 character password each time and a
different one after the second write, with the index still consistent
afterward.

A KeePassXC write asks for the master password again, because Sesam
deliberately does not keep it in memory past the export it does at unlock.
Touch ID covers that prompt when the "remember it" switch is on. The write
is followed by re-opening the database, so the in-memory index matches what
is now on disk. The login keychain stays read only throughout: the default
`create` and `regenerate` in `Source.swift` throw for any source that does
not override them, which is every source except the two vaults that can
actually accept a write.

After either write, the new password goes on the clipboard and the panel
reopens with the entry selected and a note saying what happened. A write
with no visible result is a write nobody would trust enough to use twice.

## What this gets wrong

`keepassxc-cli` addresses entries by group path and title, not by UUID, so
two entries with the same title in the same group are ambiguous and an edit
will silently pick one of them. Only groups that already exist are offered
as destinations, because creating a new group would be a second write
sitting inside the first. The recipe on each side is fixed: thirty-two
characters of letters, digits and symbols for 1Password, thirty for
KeePassXC, and neither is configurable from Sesam.

There is no undo inside Sesam, though both vaults keep their own entry
history. A 1Password write is not searchable from Sesam until the next
index rebuild, which the panel already waits for before reopening, at a
cost of about three seconds.

## Consequences

Any future write has to answer the question this one did: does the value
come from the vault or from Sesam, and why would Sesam be trusted with
generating it. So far the answer has been no every time.

`Tests/WriteTests.swift` is the gate. A change to either argument builder
that reintroduces a password as an assignment, or drops the generate flag,
fails a test before it reaches a vault that would have accepted it anyway.
</content>
