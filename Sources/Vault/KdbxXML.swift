import Foundation

/// One entry as KeePassXC exports it.
struct KdbxEntry: Equatable {
    let uuid: String
    let title: String
    let username: String
    let url: String
    let password: String
    /// Whatever the entry had to say about one-time codes: an `otpauth://`
    /// URI, or an empty string. The two ways a database can store this are
    /// normalised to that one shape by the parser, so nothing downstream has
    /// to know there were two.
    let otp: String
    /// Slash separated group path, without the root group's name.
    let group: String
}

/// The reader. 📖
///
/// `keepassxc-cli export -f xml` prints the database as the XML that lives
/// inside a `.kdbx` once it has been decrypted: groups nested in groups,
/// entries as bags of key and value pairs, passwords in the clear. This turns
/// that into a flat list.
///
/// It is a `Foundation.XMLParser` rather than a regular expression because the
/// format nests, and because two of the traps below are invisible to anything
/// that reads the document a line at a time.
///
/// **The first trap is `History`.** Every entry carries its own previous
/// versions inside a `<History>` element, as complete `<Entry>` elements with
/// their own titles and their own old passwords. A parser that treats every
/// `<Entry>` alike offers you your last five passwords for the same account,
/// with nothing on screen to say which is current. So history is counted and
/// skipped.
///
/// **The second is `UUID`.** Groups have one and entries have one, and they are
/// the same element name at different depths. The stack is what tells them
/// apart, which is why there is a stack at all.
///
/// The third is not a trap so much as a decision: the root group's name is
/// dropped from the path, because "Passwords/Banking" reads better than
/// "Root/Passwords/Banking" and every database has one.
enum KdbxXML {

    static func parse(_ data: Data) -> [KdbxEntry] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries
    }

    private final class Reader: NSObject, XMLParserDelegate {

        var entries: [KdbxEntry] = []

        private var stack: [String] = []
        private var groups: [String] = []
        private var groupIDs: [String] = []
        private var recycleBin = ""
        private var history = 0
        private var fields: [String: String] = [:]
        private var uuid = ""
        private var key = ""
        private var value = ""
        private var text = ""
        private var inEntry = false

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            stack.append(name)
            text = ""

            switch name {
            case "Group":
                groups.append("")
                groupIDs.append("")
            case "History":
                history += 1
            case "Entry":
                // An entry inside a history block is a previous version of the
                // entry that contains it. Ignore it and everything under it.
                guard history == 0 else { return }
                inEntry = true
                fields = [:]
                uuid = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            defer { if !stack.isEmpty { stack.removeLast() } }

            switch name {
            case "Name" where parent == "Group":
                if !groups.isEmpty { groups[groups.count - 1] = text }
            case "Group":
                if !groups.isEmpty { groups.removeLast() }
                if !groupIDs.isEmpty { groupIDs.removeLast() }
            case "UUID" where parent == "Group":
                if !groupIDs.isEmpty { groupIDs[groupIDs.count - 1] = text }
            case "RecycleBinUUID":
                // The all zeroes UUID is what a database with no recycle bin
                // writes, and matching on it would hide every entry.
                if text != "AAAAAAAAAAAAAAAAAAAAAA==" { recycleBin = text }
            case "History":
                history -= 1
            case "UUID" where inEntry && history == 0 && parent == "Entry":
                uuid = text
            case "Key":
                key = text
            case "Value":
                value = text
            case "String":
                guard inEntry, history == 0 else { return }
                fields[key] = value
                key = ""; value = ""
            case "Entry":
                guard inEntry, history == 0 else { return }
                inEntry = false
                // Deleted entries are still in the file, in the recycle bin
                // group. Offering somebody a password they threw away is worse
                // than not finding it.
                guard !recycleBin.isEmpty ? !groupIDs.contains(recycleBin) : true else { return }
                let title = fields["Title"] ?? ""
                guard !title.isEmpty || !(fields["UserName"] ?? "").isEmpty else { return }
                entries.append(KdbxEntry(
                    uuid: uuid,
                    title: title.isEmpty ? (fields["UserName"] ?? "(no title)") : title,
                    username: fields["UserName"] ?? "",
                    url: fields["URL"] ?? "",
                    password: fields["Password"] ?? "",
                    otp: Reader.otp(fields),
                    group: groups.dropFirst().joined(separator: "/")))
            default:
                break
            }
        }

        /// The element one level up, which is the only context any of the
        /// ambiguous element names need.
        private var parent: String { stack.count >= 2 ? stack[stack.count - 2] : "" }

        /// Two conventions, one answer.
        ///
        /// KeePassXC's own editor writes a field called `otp` holding a whole
        /// `otpauth://` URI. Databases that came from KeeWeb or from the
        /// KeeOtp plugin instead carry a bare base32 seed in `TOTP Seed` and a
        /// `period;digits` pair in `TOTP Settings`. The second shape is rebuilt
        /// into the first here, so that everything downstream reads one format.
        static func otp(_ fields: [String: String]) -> String {
            if let uri = fields["otp"], !uri.isEmpty { return uri }
            guard let seed = fields["TOTP Seed"], !seed.isEmpty else { return "" }
            let parts = (fields["TOTP Settings"] ?? "").split(separator: ";")
            let period = parts.count > 0 ? String(parts[0]) : "30"
            let digits = parts.count > 1 ? String(parts[1]) : "6"
            let escaped = seed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? seed
            return "otpauth://totp/sesam?secret=\(escaped)&period=\(period)&digits=\(digits)"
        }
    }
}
