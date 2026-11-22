import Foundation

/// The shape `op` promises, pinned. 🔐
///
/// `op item list --format json` is a contract with a program that updates
/// itself, so the fields Sesam depends on are named here. When 1Password
/// renames one, this suite is the thing that says so, rather than an empty
/// panel with no explanation.
func runOnePasswordTests() {

    let list = """
    [
      {"id":"abc","title":"GitHub","version":3,
       "vault":{"id":"v1","name":"Personal"},
       "category":"LOGIN","additional_information":"ada-lovelace",
       "urls":[{"primary":true,"href":"https://github.com"}]},
      {"id":"def","title":"Notes to self","vault":{"id":"v1","name":"Personal"},
       "category":"SECURE_NOTE","additional_information":"-"},
      {"id":"ghi","title":"Root server","vault":{"id":"v2","name":"Work"},
       "category":"SERVER","additional_information":"root"}
    ]
    """

    Check.suite("the index") {
        guard let items = Check.unwrap(try? OnePasswordSource.items(fromList: Data(list.utf8)),
                                       "the list decodes") else { return }
        Check.equal(items.count, 2, "a secure note is not something to paste into a login form")
        Check.equal(items.first?.title, "GitHub", "titles come through")
        Check.equal(items.first?.username, "ada-lovelace",
                    "the second line op prints is the username, and saves a call per row")
        Check.equal(items.first?.url, "https://github.com", "the first URL is kept")
        Check.equal(items.first?.container, "Personal", "so is the vault name")
        Check.equal(items.first?.source, SourceKind.onePassword, "and the badge is right")
    }

    Check.suite("one item's fields") {
        let fields = """
        [{"id":"username","label":"username","value":"ada-lovelace"},
         {"id":"password","label":"password","value":"hunter2"}]
        """
        guard let credential = Check.unwrap(
            try? OnePasswordSource.credential(fromFields: Data(fields.utf8)),
            "the fields decode") else { return }
        Check.equal(credential.username, "ada-lovelace", "the username is found by its id")
        Check.equal(credential.password.withString { $0 }, "hunter2", "and so is the password")
    }

    Check.suite("an item with nothing to paste") {
        let fields = """
        [{"id":"username","label":"username","value":"ada-lovelace"}]
        """
        Check.isNil(try? OnePasswordSource.credential(fromFields: Data(fields.utf8)),
                    "an item with no password is an error, not an empty paste")
    }
}
