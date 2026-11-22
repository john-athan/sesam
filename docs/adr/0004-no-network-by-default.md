# 4. No network by default, and never to an icon service

Date: 2026-09-09
Status: accepted

## Context

Sesam holds three vaults' worth of accounts in memory while unlocked. Every
feature that would reach outside the process, however small, is a channel
that could carry some part of that out with it. The clearest case is
favicons: the obvious way to make a result list recognisable at a glance is
to fetch each site's icon, one request per row, the way every browser and
most password managers already do. That request tells the site something
even when it fails: that somebody with an account there has a password
manager open right now.

Earlier drafts of this decision said Sesam opens no sockets of its own,
period. That is no longer true, and a document that keeps saying it would be
worse than one that explains the tradeoff.

## Decision

Site icons are a switch, off by default. With the switch off, Sesam makes no
requests at all, and `PanelTheme.tile(for:)` colours a monogram tile from a
fixed djb2-style hash of the entry's title: the same title always produces
the same colour, computed locally, from nothing that ever needs to leave the
process. Swift's own `hashValue` is seeded per process, which is why the
hash here is written by hand rather than borrowed; a colour drawn from the
seeded version would change on every launch and stop being a recognition aid
at all.

With the switch on, `Icons.fetch` asks the site itself, never a third party:
`https://host/favicon.ico`, then `https://host/apple-touch-icon.png` if that
fails. No HTML is parsed, so a site that only declares its icon inside a
`<link>` tag on its front page gets none, and at most two requests are ever
made per host in the life of the process. A failure is remembered in a
`tried` set so that typing the same query again does not retry it on every
keystroke. Public icon services such as Google's or DuckDuckGo's were
rejected on the ground that they would hand one company the complete list of
every service a person has an account with. Asking `example.com` for its own
icon tells `example.com` only that somebody with an account there opened
their password manager, which it could plausibly already guess.

The fetch is started from `ResultsView` while it draws each row, so an index
of thousands of entries makes no requests until a search actually brings a
row on screen. The session that makes the request is
`URLSessionConfiguration.ephemeral`, with `httpCookieStorage` set to nil, the
cookie accept policy set to never, no URL cache, a 5 second timeout, and a
neutral User-Agent string, `Mozilla/5.0 (Macintosh)`, so the request does not
announce which app made it. A shared session would carry the system cookie
store, which would turn an anonymous request into one that arrives already
signed in.

The cache lives at `~/Library/Application Support/Sesam/icons`, one file per
host, named by the SHA-256 of the host rather than the host itself, in a
directory with mode 0700, so a directory listing is not a list of accounts.
Turning the switch off deletes the whole directory. Verified live against
three public sites: all three answered, at 32x32, 96x96 and 256x256.

## What this gets wrong

Turning the switch on still tells every site with a saved login that
somebody with an account there was in their password manager, and the
timing of that request correlates with the search that triggered it. A VPN
hides where the request came from and nothing else about what it reveals.

Sites that only declare their icon in HTML get nothing, because parsing the
front page to find a 32 pixel image is more network and more parsing code
than the feature is worth for a launcher. Cached icons never expire, so a
site that rebrands keeps showing its old icon until somebody turns the
switch off and back on.

`op` talks to 1Password's own servers on Sesam's behalf regardless of this
switch, as it always has. "No network by default" was always a claim about
Sesam's own code, not about the machine Sesam runs on.

## Consequences

Every new feature gets checked against the same question this decision
answers for icons: does it need to leave the process, and if it does, what
does the request reveal on its own, independent of its response. An icon
request reveals a domain even if it 404s.

Verifying the off state holds is a matter of reading the source: with
`Icons.isEnabled` false, `fetch` returns before it builds a single URL.
Verifying the on state holds means reading `Icons.swift` end to end, because
the property that matters, at most two requests per host and never through a
public service, lives in the shape of the code rather than in one flag.
</content>
