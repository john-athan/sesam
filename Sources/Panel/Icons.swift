import Cocoa
import CryptoKit

/// The little pictures. 🖼️
///
/// A list of logins is read by shape before it is read by word, so a real site
/// icon finds the right row faster than any amount of ranking does. Getting one
/// means asking the internet, and that is the whole problem: fetching an icon
/// for every entry announces, one request at a time, which services somebody
/// has an account with.
///
/// So the rules here are about who gets told what.
///
/// **Off by default.** Sesam starts with monograms, which need nobody. The
/// menu turns fetching on, and the menu says what it costs.
///
/// **Only the site itself, never an icon service.** The obvious shortcut is
/// one of the public favicon endpoints, which would hand a single company the
/// complete list of everywhere you have an account. Asking `example.com` for
/// its own icon tells `example.com` only that somebody with an account there
/// looked at their password manager, which it could already guess.
///
/// **Only rows that are actually on screen.** Fetching is started from
/// `ResultsView` while it draws, so an index of two thousand entries makes no
/// requests at all until somebody's search brings a row up. At most two
/// requests are made per host, ever, and a failure is remembered so that
/// typing does not retry it on every keystroke.
///
/// **The cache does not spell out your accounts.** Files are named by the
/// SHA-256 of the host, in a directory that is not world readable, for the same
/// reason the frecency file holds hashes.
///
/// The trap: the session is ephemeral on purpose. A shared `URLSession` would
/// carry the system cookie store, so an icon request could arrive at a site
/// carrying a logged-in session cookie, which turns "somebody looked at their
/// password manager" into "this specific account did".
enum Icons {

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "fetchIcons") }
        set { UserDefaults.standard.set(newValue, forKey: "fetchIcons") }
    }

    /// The icon for an entry, if one is already in hand. Never blocks, never
    /// fetches: drawing code calls this.
    static func image(for item: Item) -> NSImage? {
        guard isEnabled, let host = host(of: item) else { return nil }
        if let cached = memory[host] { return cached }
        guard let data = try? Data(contentsOf: file(for: host)),
              let image = NSImage(data: data) else { return nil }
        memory[host] = image
        return image
    }

    /// Start looking, once per host per launch. `then` runs on the main thread
    /// when something new arrived, and not at all otherwise.
    static func fetch(for item: Item, then: @escaping () -> Void) {
        guard isEnabled, let host = host(of: item),
              memory[host] == nil, !tried.contains(host) else { return }
        tried.insert(host)

        // Two guesses, in the order that answers most often. Neither needs the
        // page's HTML, which would mean downloading and parsing the site's
        // front page to find a 32 pixel image.
        let candidates = ["https://\(host)/favicon.ico",
                          "https://\(host)/apple-touch-icon.png"]
        attempt(candidates, host: host, then: then)
    }

    static func forget() {
        memory = [:]
        tried = []
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - the machinery

    private static var memory: [String: NSImage] = [:]
    private static var tried: Set<String> = []

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh)"]
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()

    /// A 302 to somewhere else is the way around `isPublic`, so the same
    /// question is asked again of wherever a site tries to send us, and a
    /// redirect out of https is refused rather than followed.
    private static let redirects = Redirects()

    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, url.scheme == "https",
                  let host = url.host, Icons.isPublic(host.lowercased()) else {
                return completionHandler(nil)
            }
            completionHandler(request)
        }
    }

    private static func attempt(_ urls: [String], host: String,
                                then: @escaping () -> Void) {
        guard let next = urls.first, let url = URL(string: next) else { return }
        session.dataTask(with: url) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 200 KB is far more than an icon and far less than a page that
            // answered with its front end instead of a 404.
            if code == 200, let data, data.count < 200_000,
               let image = NSImage(data: data), image.size.width > 0 {
                store(image, data: data, host: host)
                DispatchQueue.main.async { then() }
            } else {
                attempt(Array(urls.dropFirst()), host: host, then: then)
            }
        }.resume()
    }

    private static func store(_ image: NSImage, data: Data, host: String) {
        DispatchQueue.main.async { memory[host] = image }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: file(for: host), options: [.atomic])
    }

    /// The host an entry belongs to, or nil when it has no URL to belong to.
    static func host(of item: Item) -> String? {
        guard let raw = item.url, !raw.isEmpty else { return nil }
        let text = raw.contains("://") ? raw : "https://" + raw
        guard let components = URLComponents(string: text),
              let host = components.host,
              components.scheme == "https" || components.scheme == "http"
        else { return nil }
        let name = host.lowercased()
        return isPublic(name) ? name : nil
    }

    /// A name on the public internet, and not an address.
    ///
    /// The check exists because an entry's URL is not trustworthy input. Any
    /// process running as this user can add an internet password to the login
    /// keychain with any server name it likes, without a prompt, and that entry
    /// turns up in Sesam's index with a URL built from it. Without this, a
    /// crafted entry could point the icon fetcher at `169.254.169.254` or at
    /// something on the local network and use Sesam as a probe. So literal
    /// addresses are refused outright, and so are the suffixes that mean "not
    /// the internet".
    ///
    /// What this does not stop: a public name whose DNS answer is a private
    /// address. Refusing that would mean resolving the name here and pinning
    /// the answer, which is a great deal of machinery for an optional feature
    /// that is off by default.
    static func isPublic(_ host: String) -> Bool {
        if host.contains(":") { return false }                    // an IPv6 literal
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return false }             // localhost, a bare word
        // inet_aton is the parser the resolver itself uses, so it accepts every
        // spelling of an IPv4 literal (0x7f.0.0.1, 0177.0.0.1, 127.1) that a
        // digits-only test lets through to the local network.
        var address = in_addr()
        if inet_aton(host, &address) != 0 { return false }
        let suffix = labels.last.map(String.init) ?? ""
        return !["local", "internal", "localhost", "arpa", "home", "lan", "test"].contains(suffix)
    }

    static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sesam/icons", isDirectory: true)
    }

    /// Named by hash, so a directory listing is not a list of the services
    /// somebody uses.
    static func file(for host: String) -> URL {
        let name = SHA256.hash(data: Data(host.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".img")
    }
}
