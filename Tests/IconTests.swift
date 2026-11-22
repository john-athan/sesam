import Foundation

/// Which entries have a host, and what the cache is allowed to say. 🖼️
func runIconTests() {

    func item(_ url: String?) -> Item {
        Item(id: "x", title: "Example", username: nil, url: url,
             container: nil, source: .onePassword)
    }

    Check.suite("finding the host") {
        Check.equal(Icons.host(of: item("https://github.com")), "github.com", "the plain case")
        Check.equal(Icons.host(of: item("https://GitHub.com/login")), "github.com",
                    "case folded, path ignored")
        Check.equal(Icons.host(of: item("github.com")), "github.com",
                    "a URL with no scheme is assumed to be https")
        Check.equal(Icons.host(of: item("https://sub.example.co.uk/x?y=1")), "sub.example.co.uk",
                    "subdomains are kept, because their icons differ")
        Check.isNil(Icons.host(of: item(nil)), "an entry with no URL has no host")
        Check.isNil(Icons.host(of: item("")), "nor has an empty one")
        Check.isNil(Icons.host(of: item("localhost")), "a bare word is not a host")
        Check.isNil(Icons.host(of: item("ssh://git@example.com")),
                    "and a scheme nothing can be fetched over is refused rather than rewritten")
    }

    Check.suite("an entry URL is not trusted input") {
        // Any process running as this user can add an internet password to the
        // login keychain with any server it likes, and that entry appears in
        // Sesam's index with a URL built from it. Without this check, such an
        // entry could aim the icon fetcher at the local network.
        for address in ["127.0.0.1", "169.254.169.254", "10.0.0.1", "192.168.1.1",
                        "0.0.0.0", "8.8.8.8", "0x7f.0.0.1", "0177.0.0.1", "127.1",
                        "0xa9.0xfe.0xa9.0xfe"] {
            Check.that(!Icons.isPublic(address), "\(address) is an address, not a name")
            Check.isNil(Icons.host(of: item("https://\(address)/favicon.ico")),
                        "and never becomes a host to fetch from")
        }
        for name in ["localhost", "router", "printer.local", "vault.internal",
                     "box.home", "nas.lan", "1.0.0.127.in-addr.arpa"] {
            Check.that(!Icons.isPublic(name), "\(name) does not name the public internet")
        }
        Check.that(!Icons.isPublic("fe80::1"), "nor does an IPv6 literal")
        for name in ["github.com", "sub.example.co.uk", "1password.com", "e5.nu"] {
            Check.that(Icons.isPublic(name), "\(name) is an ordinary host")
        }
    }

    Check.suite("the cache names no names") {
        let file = Icons.file(for: "github.com").lastPathComponent
        Check.that(!file.contains("github"), "a directory listing is not a list of your accounts")
        Check.equal(file.count, 68, "a SHA-256 in hex, plus the extension")
        Check.equal(Icons.file(for: "github.com"), Icons.file(for: "github.com"),
                    "the same host is the same file every time")
        Check.that(Icons.file(for: "github.com") != Icons.file(for: "gitlab.com"),
                   "and two hosts are two files")
    }

    Check.suite("nothing happens while it is switched off") {
        Check.that(!Icons.isEnabled, "fetching is off until somebody turns it on")
        Check.isNil(Icons.image(for: item("https://github.com")),
                    "so there is no icon to draw")
    }
}
