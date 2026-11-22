import Foundation

/// What a write command may and may not contain. ✍️
///
/// The rule these suites exist to keep: **the password is never an argument.**
/// Every process on a Mac can read every other process's argument list through
/// `ps`, for as long as the command runs, so a generated password passed on the
/// command line is a password handed to anything that happens to be looking.
/// Both vaults can generate their own, so both are told to, and these checks
/// fail the day somebody makes that convenient instead.
func runWriteTests() {

    let draft = Draft(title: "Example Site", username: "alice",
                      url: "https://example.com", destination: "Personal")
    let bare = Draft(title: "Just a title", username: "", url: "", destination: "")

    Check.suite("1Password: the vault generates it") {
        let arguments = OnePasswordSource.createArguments(draft)
        Check.that(arguments.contains("--generate-password=\(OnePasswordSource.recipe)"),
                   "the password is asked for, not supplied")
        Check.that(!arguments.contains { $0.hasPrefix("password=") },
                   "and never appears as an assignment statement")
        Check.that(arguments.contains("username=alice"),
                   "the username does, because it is not a secret")
        Check.that(arguments.contains("--vault") && arguments.contains("Personal"),
                   "the chosen vault is passed")
        Check.that(arguments.contains("--url") && arguments.contains("https://example.com"),
                   "so is the URL")
        Check.that(arguments.contains("--format") && arguments.contains("json"),
                   "and the answer is asked for as JSON, so the new id can be read back")
    }

    Check.suite("1Password: what an empty form leaves out") {
        let arguments = OnePasswordSource.createArguments(bare)
        Check.that(!arguments.contains("--vault"), "no vault means op's own default")
        Check.that(!arguments.contains("--url"), "no URL means no flag")
        Check.that(!arguments.contains { $0.hasPrefix("username=") }, "and no username assignment")
        Check.that(arguments.contains("Just a title"), "the title always survives")
    }

    Check.suite("1Password: replacing a password") {
        let arguments = OnePasswordSource.editArguments(for: "abc123")
        Check.that(arguments.contains("abc123"), "the item is named by id, not by title")
        Check.that(arguments.contains("--generate-password=\(OnePasswordSource.recipe)"),
                   "and the new password is 1Password's to make")
        Check.that(!arguments.contains { $0.contains("=") && $0.hasPrefix("password") },
                   "nothing carries a secret")
    }

    Check.suite("KeePassXC: the same rule") {
        let arguments = KeePassSource.addArguments(draft)
        Check.that(arguments.contains("-g"), "keepassxc-cli generates the password")
        Check.that(arguments.contains("-L") && arguments.contains("30"),
                   "at the length KeePassXC's own settings use")
        Check.that(arguments.contains("-u") && arguments.contains("alice"), "username is passed")
        Check.that(arguments.contains("--url"), "so is the URL")
        Check.that(!arguments.contains("-p"),
                   "and it is never asked to prompt for a password Sesam would have to invent")
        Check.that(KeePassSource.editArguments.contains("-g"),
                   "replacing a password generates one too")
    }

    Check.suite("KeePassXC: where a new entry lands") {
        Check.equal(KeePassSource.path(for: draft), "Personal/Example Site",
                    "a group and a title make a path")
        Check.equal(KeePassSource.path(for: bare), "Just a title",
                    "and no group means the root, which is what an empty destination is")
    }

    Check.suite("a title that cannot be addressed is refused, not guessed at") {
        // keepassxc-cli takes a slash separated path and offers no escape, so
        // an entry called "Bank/Root Password" in the root group has the same
        // address as "Root Password" inside a group called "Bank". Writing to
        // one would land on the other.
        Check.throwsError("a slash in a title stops a write") {
            try KeePassSource.checkAddressable("Bank/Root Password")
        }
        Check.equal(KeePassSource.path(for: Draft(title: "Root Password", username: "",
                                                  url: "", destination: "Bank")),
                    "Bank/Root Password",
                    "which is the very address the decoy would have produced")
        do {
            try KeePassSource.checkAddressable("Corner Bank")
            Check.that(true, "an ordinary title is fine")
        } catch {
            Check.that(false, "an ordinary title is fine")
        }
    }

    Check.suite("nothing writes to the keychain") {
        let keychain = KeychainSource()
        Check.equal(keychain.destinations.count, 0, "it offers nowhere to write")
        Check.throwsError("and refuses if asked anyway") {
            _ = try keychain.create(draft)
        }
        Check.throwsError("including a password replacement") {
            try keychain.regenerate(for: Item(id: "x", title: "x", username: nil, url: nil,
                                              container: nil, source: .keychain))
        }
    }
}
