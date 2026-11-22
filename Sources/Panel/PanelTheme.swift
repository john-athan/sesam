import Cocoa

/// The palette. 🎨
///
/// Every colour and font the panel uses, in one place.
///
/// **Semantic colours only.** `labelColor` and its quieter siblings know what
/// to do in light appearance, in dark appearance, in increased contrast and on
/// top of a vibrant material. A hand picked grey knows none of that and looks
/// wrong in exactly the one nobody checked. The single exception is the
/// selection fill, which is the user's own accent colour.
///
/// **One accent, and it belongs to the selected row.** Everything else is the
/// system's greys. The panel is looked at for half a second at a time, and in
/// that half second there is exactly one thing to find: which row Enter will
/// act on.
enum PanelTheme {

    static let title = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let subtitle = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let badge = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let field = NSFont.systemFont(ofSize: 26, weight: .light)
    static let monogram = NSFont.systemFont(ofSize: 15, weight: .medium)

    static var selection: NSColor { .controlAccentColor.withAlphaComponent(0.85) }
    static var selectedText: NSColor { .white }
    static var titleText: NSColor { .labelColor }
    static var subtitleText: NSColor { .secondaryLabelColor }
    static var badgeText: NSColor { .tertiaryLabelColor }
    /// The key legend is read, not glanced at, so it is not tertiary.
    /// Composited over the panel, `tertiaryLabelColor` measures about 1.9:1 in
    /// light appearance and 2.3:1 in dark, under the 3:1 asked even of large
    /// text; `secondaryLabelColor` clears it in both.
    static var legend: NSColor { .secondaryLabelColor }
    static var line: NSColor { .separatorColor }

    /// The tile behind an entry's initial. Hue comes from the title, so the
    /// same entry is the same colour every time and two neighbours are usually
    /// not, which is the whole job: a shape to aim at while the eyes are still
    /// moving.
    ///
    /// The trap: `hashValue` is seeded per process in Swift, so a colour drawn
    /// from it would be a different colour after every launch. This is a fixed
    /// hash for that reason, not for speed.
    static func tile(for text: String) -> NSColor {
        var h: UInt32 = 5381
        for byte in text.lowercased().utf8 { h = h &* 33 &+ UInt32(byte) }
        return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.45, brightness: 0.72, alpha: 1)
    }
}
