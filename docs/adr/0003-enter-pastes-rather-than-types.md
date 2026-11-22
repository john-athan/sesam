# 3. Enter pastes rather than types

Date: 2026-09-09
Status: accepted

## Context

Once `secret(for:)` has a password, it still has to arrive in whatever login
field was in front when Option-Space was pressed. There are three ways to
move a string from Sesam's process into another application's focused field:
post a synthetic Command-V after putting the string on the clipboard,
synthesise the password one character at a time with a keyboard event API, or
walk the target application's accessibility tree and set the field's value
directly.

## Decision

Paste.

`SearchPanelController` records `NSWorkspace.shared.frontmostApplication`
before the panel appears, as `caller`, and that recorded application is where
Enter delivers to, not whatever happens to be frontmost by the time the
fetch finishes. On Enter, `Deliver.paste` reactivates `caller`, writes the
password to `NSPasteboard.general`, waits 120 milliseconds, then posts one
synthetic Command-V through `CGEvent`, and 350 milliseconds after that either
restores whatever string was on the clipboard before or clears it if there
was nothing.

The 120 millisecond wait exists because the keystroke is posted to the
session, not to a specific window, so it lands wherever the window server
believes focus is at that instant. Posting it before `caller.activate()` has
actually finished would send Command-V into whatever was frontmost a moment
ago, not into the application Sesam is trying to fill. Every write to the
clipboard also carries the `org.nspasteboard.ConcealedType` marker, which is
the convention clipboard managers watch for to know an entry must not be
recorded, and the eventual clear only happens if `NSPasteboard.changeCount`
still matches what Sesam itself wrote; if something else copied in the
meantime, `shouldClear` refuses, so Sesam never throws away somebody else's
clipboard contents on its way out.

Synthesising the password character by character was rejected. It depends on
the keyboard layout active in the target application, arrives slowly enough
to be visible, and a field that rejects synthetic key events one at a time
(several do, inconsistently) fails silently rather than falling back to
anything. Walking the accessibility tree was rejected too: it needs
per-application knowledge to find the right field, and the case that matters
most, a browser's own web content, exposes no such tree to accessibility
APIs at all.

**The permission split matters as much as the mechanism.** Posting a
synthetic keyboard event requires the Accessibility grant; reading a keychain
item, calling `op item get`, and writing to the clipboard do not. That is why
Command-C and Command-B work on a fresh install with no dialog at all, and
only pressing Enter sends anybody to System Settings, in `Accessibility.swift`.
A password manager that demands system-wide control before it will show
anything is one people quit before they finish setting it up.

## What this gets wrong

The password touches the real, general clipboard. A clipboard manager that
does not honour the `org.nspasteboard.ConcealedType` convention will record
it regardless of what Sesam intended.

The 120 millisecond delay before posting Command-V is a number measured on
one Mac across twenty tries, not a value derived from anything the window
server documents. A slower machine, or a target application that is slow to
actually take focus once `activate()` returns, can still lose the race.

Restoring the previous clipboard only restores a plain string, because that
is what `NSPasteboard.general.string(forType:)` can read back. A copied
image or file that was on the clipboard before Enter was pressed is gone
after the restore, not preserved.

If focus is not where the user believes it is, whether because a dialog
opened underneath the panel or because the previous application took longer
than 120 milliseconds to come forward, the password is pasted into whatever
field does have focus, in the clear, with no confirmation step in between.

## Consequences

`Deliver` is the only place in Sesam that touches `NSPasteboard` or posts a
synthetic event, which is what makes the concealment and restore logic
auditable in one file rather than scattered across every call site that
needs to deliver something.

The clipboard clear timer and the Accessibility check are both independent
of which source the password came from. Adding a fourth vault later changes
nothing about how delivery works, because delivery never learns which source
a `Credential` came from in the first place.
