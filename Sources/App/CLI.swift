import Cocoa

/// The gate. 🚪
///
/// One binary, two lives:
///   • no arguments  → the menu bar app
///   • a subcommand  → a few words about the running one, and then out
///
/// The CLI is deliberately thin. It can ask what state Sesam is in and it can
/// tell it to lock, and that is all: a command that printed passwords would put
/// them in a shell history, a terminal scrollback buffer and quite possibly a
/// screen sharing session, which is three places Sesam otherwise keeps them
/// out of. `op` already exists for people who want that.
///
/// Locking is a distributed notification rather than a socket or a file,
/// because the running app is a different process and this is the cheapest
/// thing macOS has that crosses that line.
func runCLI(_ args: [String]) -> Int32? {
    guard let first = args.first else { return nil }

    switch first {
    case "lock":
        DistributedNotificationCenter.default()
            .postNotificationName(NSNotification.Name("io.github.john-athan.sesam.lock"),
                                  object: nil, userInfo: nil, deliverImmediately: true)
        print("locked")
        return 0

    case "search":
        // The same thing Option-Space does, for anybody who would rather bind
        // it in their own launcher. It opens the panel and nothing else: no
        // query on the command line, because a search term for a password
        // manager in a shell history is a list of what to try first.
        DistributedNotificationCenter.default()
            .postNotificationName(NSNotification.Name("io.github.john-athan.sesam.search"),
                                  object: nil, userInfo: nil, deliverImmediately: true)
        return 0

    case "status":
        let running = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "io.github.john-athan.sesam" }
        print(running ? "Sesam is running. Press Option-Space." : "Sesam is not running.")
        for kind in SourceKind.allCases {
            let hint: String
            switch kind {
            case .onePassword:
                hint = Shell.locate(OnePasswordSource.candidates) ?? "op is not installed"
            case .keePass:
                hint = KeePassSource.databasePath ?? "no database chosen"
            case .keychain:
                hint = "login.keychain-db"
            }
            print("  \(kind.label): \(hint)")
        }
        return 0

    case "index":
        // A smoke test that needs no window: build the index the panel would
        // search and say how big it is. Counts only. A subcommand that printed
        // entry titles would put the list of every account you have into a
        // terminal scrollback, which is one of the places Sesam exists to keep
        // them out of.
        for kind in SourceKind.allCases {
            guard let source = Vault.shared.source(kind) else { continue }
            let started = Date()
            do {
                let items = try source.index()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("  \(kind.label): \(items.count) items in \(ms) ms")
            } catch {
                print("  \(kind.label): \(error.localizedDescription)")
            }
        }
        return 0

    case "-h", "--help", "help":
        print("""
        sesam - one search bar over 1Password, KeePassXC and the Keychain.

          sesam            launch the menu bar app
          sesam status     what is configured, and whether the app is running
          sesam index      count what each source can see, without showing any of it
          sesam search     open the panel, the same as Option-Space
          sesam lock       drop every unlocked vault right now
          sesam help       this

        Everything else is Option-Space.
        """)
        return 0

    default:
        FileHandle.standardError.write(
            Data("sesam: unknown command '\(first)'. Try `sesam help`.\n".utf8))
        return 2
    }
}
