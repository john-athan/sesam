# 5. Lock is a real state

Date: 2026-09-09
Status: accepted

## Context

Sesam holds decrypted passwords in memory for as long as it is unlocked. A
menu bar utility that only ever hides its window when nobody is looking is
not locked in any sense that matters, it is just not currently on screen. If
lock is going to mean anything, it has to actually remove what it claims to
remove, and it has to fire on its own on the occasions a Mac stops being
watched, not only when somebody remembers to click a menu item.

## Decision

`Vault.lock()` drops the merged `items` array, calls `lock()` on every
source so each one lets go of whatever it was holding, clears the clipboard
through `Deliver.clear()`, and closes the panel. Afterward the menu bar reads
"Sesam, locked" and the search panel finds nothing at all, because the index
it searches no longer exists.

Four triggers call it, all in `MenuBarApp.swift`. `NSWorkspace.willSleepNotification`
fires when the Mac is about to sleep. The distributed notification
`com.apple.screenIsLocked` fires when the screen locks, whether or not the
Mac itself sleeps. An idle timer, `Timer.scheduledTimer` on a 60 second
interval, checks how long it has been since the last search and locks after
15 minutes of silence by default, configurable to 5, 60, or never through the
Settings submenu. `sesam lock`, sent as a distributed notification from a
second invocation of the binary, lets a terminal command lock a running
instance without reaching into its process any other way.

`Hardening.apply()` runs once at launch and sets `RLIMIT_CORE` to zero, so
that a crash while Sesam is unlocked cannot write the process's memory,
decrypted database included, to a core file on disk. It is not a lock trigger
itself, it is what keeps a crash from being a worse leak than a lock would
have prevented.

## What this gets wrong

The keychain source cannot actually be locked, and `KeychainSource.lock()`
says so in a comment rather than pretending: macOS unlocked the login
keychain at login, before Sesam ever ran, and Sesam has no API that would
lock it back up. Calling `Vault.lock()` removes the keychain's items from
Sesam's own index, but the very next search rebuilds that index from the
same still-unlocked keychain, because nothing about the keychain's own state
changed.

1Password's session belongs to `op` and to the 1Password desktop app, not to
Sesam. `OnePasswordSource.lock()` only resets a count Sesam kept for display;
it does not sign `op` out or end the session with the desktop app, so the
next `op item list` after a Sesam lock can still answer instantly if that
session is still warm.

Locking wipes the `Secret` buffers Sesam itself allocated, not every place a
password's bytes ever passed through on the way in. A master password typed
into `Unlock.ask(for:)` arrives as an `NSSecureTextField`'s `String`, and a
`String` cannot be overwritten; the field's own copy is released, not
scrubbed, when the alert closes. Lock is honest about the buffers it owns.
It is not a claim about every page of memory a password has ever touched.

The optional "Remember its password, behind Touch ID" switch takes the master
password out of memory's reach entirely and puts it in the login keychain,
where a lock does not touch it and cannot. That is the point of the switch and
also its cost, which is why it is off by default and why `TouchID.swift` spells
out what the fingerprint sheet does and does not stop. Turning it off deletes
the item.

`PT_DENY_ATTACH` is absent from `Hardening.swift`, and the reason first
written here was wrong. It said the call stops nothing that root cannot undo.
That is true of a binary signed with a Developer ID and the hardened runtime,
where attaching already requires an entitlement. Sesam is ad-hoc signed and
has neither, so a process running as this user can attach a debugger and read
the unlocked vault out of memory without being root, which is the threat that
matters most rather than one that does not. The call is still not made,
because it is bypassable by that same attacker and because it would have
blocked the `sample` that diagnosed a real report. What follows from that is a
documented property, not a mitigation: against code running as you, an
unlocked Sesam loses.

## Consequences

A locked Sesam is genuinely empty for two of its three sources. Reopening
the panel after a lock shows nothing until KeePassXC is unlocked again by
hand and 1Password's own session, if it lapsed, prompts Touch ID again on
the next fetch.

The idle timer's cost is one 60 second tick checking one timestamp, never
polling a source or the network, which is why it is safe to leave running
for the life of the app rather than starting and stopping it around panel
visibility.
