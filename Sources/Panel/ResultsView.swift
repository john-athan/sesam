import Cocoa

/// The list. 📋
///
/// One view that draws every row, rather than a table view with a data source,
/// a delegate, a cell prototype and a reuse queue. There are at most eight rows
/// and they are redrawn on every keystroke, so the machinery an `NSTableView`
/// exists to provide (recycling, lazy loading, selection state) is machinery
/// with nothing to do here.
///
/// Geometry comes from `PanelLayout`, colours from `PanelTheme`, and this file
/// is the part in the middle that puts text in rectangles.
///
/// The trap: this view is flipped, matching `PanelLayout`. Anything added later
/// that computes a y coordinate by subtracting from `bounds.height` will be
/// upside down and will look almost right, which is worse.
final class ResultsView: NSView {

    var items: [Item] = [] { didSet { needsDisplay = true } }
    var selected: Int = 0 { didSet { needsDisplay = true } }
    /// A line to show in place of one row's subtitle: the revealed password
    /// after Command-Shift-R, or "waiting for 1Password" while a vault is
    /// taking its time. One slot, because only ever one row is saying
    /// something other than what it normally says.
    var note: (index: Int, text: String)? { didSet { needsDisplay = true } }

    /// What the row under the mouse should do: the panel supplies this so the
    /// view stays ignorant of vaults.
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        // The hairline the field sits on. Drawn here rather than as a view of
        // its own because it belongs to the list: with no results there is no
        // list and no line, and the panel is a bare field.
        if !items.isEmpty {
            PanelTheme.line.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: PanelLayout.divider).fill()
        }
        drawFooter()
        for (index, item) in items.enumerated() {
            let row = PanelLayout.row(index, width: bounds.width)
                .offsetBy(dx: 0, dy: PanelLayout.divider)
            guard row.intersects(dirty) else { continue }
            draw(item, in: row, chosen: index == selected,
                 note: note?.index == index ? note?.text : nil)
        }
    }

    /// The legend. Written out rather than hidden behind a help key, because
    /// the first question anybody has in front of a search bar with no buttons
    /// is what happens when they press something.
    private func drawFooter() {
        guard !items.isEmpty else { return }
        let rect = PanelLayout.footer(rows: items.count, width: bounds.width)
        PanelTheme.line.setFill()
        NSRect(x: 0, y: rect.minY, width: bounds.width, height: 1).fill()

        let keys = selected < items.count && items[selected].isAction
            ? "⏎  unlock"
            : "⌘C  password      ⌘B  username      ⌘T  code      ⏎  fill"
                + "      ⌘N  new      ⌘E  replace      ⌘⇧R  reveal"
        text(keys, in: rect.insetBy(dx: PanelLayout.margin, dy: 5),
             PanelTheme.badge, PanelTheme.legend)
    }

    private func draw(_ item: Item, in row: NSRect, chosen: Bool, note: String?) {
        if chosen {
            PanelTheme.selection.setFill()
            NSBezierPath(roundedRect: PanelLayout.selection(in: row),
                         xRadius: 8, yRadius: 8).fill()
        }

        monogram(item, in: PanelLayout.icon(in: row))

        let badgeText = item.source.badge as NSString
        let badgeWidth = badgeText.size(withAttributes: [.font: PanelTheme.badge]).width + 12
        let (titleRect, subtitleRect) = PanelLayout.text(in: row, badge: badgeWidth)

        let primary = chosen ? PanelTheme.selectedText : PanelTheme.titleText
        let secondary = chosen ? PanelTheme.selectedText.withAlphaComponent(0.8)
                               : PanelTheme.subtitleText

        text(item.title, in: titleRect, PanelTheme.title, primary)
        text(note ?? subtitle(of: item), in: subtitleRect, PanelTheme.subtitle, secondary)

        let badgeRect = PanelLayout.badge(in: row, width: badgeWidth)
        (chosen ? PanelTheme.selectedText.withAlphaComponent(0.25)
                : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5).fill()
        text(item.source.badge, in: badgeRect.insetBy(dx: 0, dy: 1), PanelTheme.badge,
             chosen ? PanelTheme.selectedText : PanelTheme.badgeText, centred: true)
    }

    /// Username first, because that is what tells two entries for the same site
    /// apart. The container is the tiebreaker after that.
    private func subtitle(of item: Item) -> String {
        [item.username, item.container].compactMap { $0 }.joined(separator: "  ·  ")
    }

    /// The site's own icon when there is one, and a letter on a coloured tile
    /// when there is not. The fetch is started from here rather than from the
    /// controller because here is the only place that knows which rows are
    /// actually on screen.
    private func monogram(_ item: Item, in rect: NSRect) {
        if let icon = Icons.image(for: item) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).setClip()
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        PanelTheme.tile(for: item.title).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let initial = String(item.title.first.map(String.init)?.uppercased() ?? "?")
        text(initial, in: rect.insetBy(dx: 0, dy: 6), PanelTheme.monogram, .white, centred: true)
        Icons.fetch(for: item) { [weak self] in self?.needsDisplay = true }
    }

    private func text(_ string: String, in rect: NSRect, _ font: NSFont,
                      _ colour: NSColor, centred: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centred ? .center : .left
        (string as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: colour, .paragraphStyle: style,
        ])
    }

    // MARK: - the mouse, for completeness

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - PanelLayout.divider) / PanelLayout.rowHeight)
        guard items.indices.contains(index) else { return }
        selected = index
        onClick?(index)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.y - PanelLayout.divider) / PanelLayout.rowHeight)
        if items.indices.contains(index) { selected = index }
    }
}
