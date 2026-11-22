import Foundation

/// What "the right first result" means, written down. 🥇
///
/// Every check here is a sentence somebody would say about the panel: typing
/// two letters of a name should put that name first, an old favourite should
/// not outrank a better match, and a password that is genuinely not there
/// should produce nothing rather than the least bad row.
func runRankerTests() {

    func item(_ title: String, _ user: String? = nil, _ url: String? = nil,
              _ source: SourceKind = .keychain) -> Item {
        Item(id: title, title: title, username: user, url: url,
             container: "Vault", source: source)
    }

    let github = item("GitHub", "ada-lovelace", "https://github.com")
    let gitlab = item("GitLab", "al")
    let bank = item("Corner Bank", "1234567")
    let mail = item("Aurora Mail", "ada@fjord.example", "https://mail.example.com")
    let all = [github, gitlab, bank, mail]

    let none: (String) -> Int = { _ in 0 }

    Check.suite("ranking") {
        Check.equal(Ranker.rank(all, query: "git", frecency: none).first?.title, "GitHub",
                    "a prefix shared by two entries picks the shorter title first")
        Check.equal(Ranker.rank(all, query: "gitlab", frecency: none).first?.title, "GitLab",
                    "an exact title wins outright")
        Check.equal(Ranker.rank(all, query: "bank", frecency: none).first?.title, "Corner Bank",
                    "a word inside the title is found")
        Check.equal(Ranker.rank(all, query: "fjord", frecency: none).first?.title, "Aurora Mail",
                    "the username is searched as well as the title")
        Check.equal(Ranker.rank(all, query: "xyzzy", frecency: none).count, 0,
                    "no match means no rows, not a bad guess")
        Check.equal(Ranker.rank(all, query: "  ", frecency: none).count, all.count,
                    "whitespace is not a query")
    }

    Check.suite("frecency breaks ties and nothing else") {
        let favourite: (String) -> Int = { $0 == gitlab.key ? 50 : 0 }
        Check.equal(Ranker.rank(all, query: "", frecency: favourite).first?.title, "GitLab",
                    "with nothing typed, the most used entry leads")
        Check.equal(Ranker.rank(all, query: "github", frecency: favourite).first?.title, "GitHub",
                    "a used entry cannot climb over an exact match on another")
    }

    Check.suite("subsequence, the last rung") {
        Check.that(Ranker.isSubsequence("ghb", of: "github"), "ghb is inside github, in order")
        Check.that(!Ranker.isSubsequence("bhg", of: "github"), "order matters")
        Check.that(Ranker.isSubsequence("", of: "github"), "an empty needle is everywhere")
        Check.that(Ranker.wordPrefix("corner bank", "bank"), "words split on spaces")
        Check.that(Ranker.wordPrefix("ada-lovelace", "lovelace"), "and on dashes")
        Check.that(!Ranker.wordPrefix("github", "hub"), "a word prefix is not a substring")
    }

    Check.suite("the panel's limit is respected") {
        let many = (0..<40).map { item("Entry \($0)") }
        Check.equal(Ranker.rank(many, query: "entry", frecency: none).count, Ranker.limit,
                    "never more rows than the panel draws")
    }
}
