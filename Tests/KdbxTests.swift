import Foundation

/// The two things a naive KDBX reader gets wrong. 📖
///
/// The fixture is invented, but its shape is the real one, taken from a
/// database created with `keepassxc-cli db-create` and exported: entries as
/// bags of Key and Value pairs, a `History` block holding complete previous
/// versions of an entry, and a recycle bin identified by a UUID in `Meta`.
func runKdbxTests() {

    let xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <KeePassFile>
      <Meta>
        <Generator>KeePassXC</Generator>
        <RecycleBinUUID>UkVDWUNMRUJJTgAAAAAAAA==</RecycleBinUUID>
      </Meta>
      <Root>
        <Group>
          <UUID>Um9vdAAAAAAAAAAAAAAAAA==</UUID>
          <Name>Passwords</Name>
          <Entry>
            <UUID>RW50cnkxAAAAAAAAAAAAAA==</UUID>
            <String><Key>Title</Key><Value>Example Site</Value></String>
            <String><Key>UserName</Key><Value>alice</Value></String>
            <String><Key>Password</Key><Value ProtectInMemory="True">hunter2</Value></String>
            <String><Key>URL</Key><Value>https://example.com</Value></String>
            <String><Key>otp</Key><Value>otpauth://totp/Example?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&amp;digits=8</Value></String>
            <History>
              <Entry>
                <UUID>T2xkRW50cnkAAAAAAAAAAA==</UUID>
                <String><Key>Title</Key><Value>Example Site</Value></String>
                <String><Key>Password</Key><Value>correcthorse</Value></String>
              </Entry>
            </History>
          </Entry>
          <Group>
            <UUID>QmFua2luZwAAAAAAAAAAAA==</UUID>
            <Name>Banking</Name>
            <Entry>
              <UUID>RW50cnkyAAAAAAAAAAAAAA==</UUID>
              <String><Key>Title</Key><Value>Corner Bank</Value></String>
              <String><Key>TOTP Seed</Key><Value>GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ</Value></String>
              <String><Key>TOTP Settings</Key><Value>60;8</Value></String>
              <String><Key>UserName</Key><Value>bob</Value></String>
              <String><Key>Password</Key><Value>zweitens</Value></String>
              <String><Key>URL</Key><Value/></String>
            </Entry>
          </Group>
          <Group>
            <UUID>UkVDWUNMRUJJTgAAAAAAAA==</UUID>
            <Name>Recycle Bin</Name>
            <Entry>
              <UUID>RGVsZXRlZAAAAAAAAAAAAA==</UUID>
              <String><Key>Title</Key><Value>Old Router</Value></String>
              <String><Key>Password</Key><Value>admin</Value></String>
            </Entry>
          </Group>
        </Group>
      </Root>
    </KeePassFile>
    """

    let entries = KdbxXML.parse(Data(xml.utf8))

    Check.suite("the export is read") {
        Check.equal(entries.count, 2, "two live entries, and only two")
        Check.equal(entries.first?.title, "Example Site", "titles survive")
        Check.equal(entries.first?.username, "alice", "so do usernames")
        Check.equal(entries.first?.password, "hunter2", "and the password is the current one")
        Check.equal(entries.first?.url, "https://example.com", "and the URL")
    }

    Check.suite("history is not a list of your old passwords") {
        Check.that(!entries.contains { $0.password == "correcthorse" },
                   "a previous version of an entry is never offered")
        Check.equal(entries.first?.uuid, "RW50cnkxAAAAAAAAAAAAAA==",
                    "and it does not steal the live entry's identity")
    }

    Check.suite("groups and the bin") {
        Check.equal(entries.last?.group, "Banking", "the root group is dropped from the path")
        Check.that(!entries.contains { $0.title == "Old Router" },
                   "a deleted entry stays deleted")
    }

    Check.suite("one-time codes, in both of the shapes databases use") {
        guard let first = Check.unwrap(entries.first, "the first entry"),
              let last = Check.unwrap(entries.last, "the second") else { return }

        guard let uri = Check.unwrap(TOTP.settings(from: first.otp),
                                     "KeePassXC's own otp field is a whole URI") else { return }
        Check.equal(uri.digits, 8, "and its query is read")
        Check.equal(TOTP.code(uri, at: Date(timeIntervalSince1970: 59)), "94287082",
                    "which produces the RFC's code")

        guard let pair = Check.unwrap(TOTP.settings(from: last.otp),
                                      "a KeeWeb style seed and settings pair also works") else { return }
        Check.equal(pair.period, 60, "the period comes from TOTP Settings")
        Check.equal(pair.digits, 8, "and so do the digits")
        Check.equal(pair.secret, Array("12345678901234567890".utf8), "the seed decodes")
    }

    Check.suite("nothing at all") {
        Check.equal(KdbxXML.parse(Data()).count, 0, "empty input parses to nothing, not a crash")
        Check.equal(KdbxXML.parse(Data("<KeePassFile><Root/></KeePassFile>".utf8)).count, 0,
                    "an empty database is empty")
    }
}
