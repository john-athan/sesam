import CoreGraphics

/// The grid. 📐
///
/// Pure arithmetic, no AppKit, no drawing, so the panel's geometry can be
/// checked in a test that never opens a window. Every rectangle the panel draws
/// is computed here and painted somewhere else.
///
/// The measurements are Spotlight's, near enough that muscle memory carries
/// over: a wide field you can read a whole URL in, rows tall enough for two
/// lines of text, and a panel that sits a little above the middle of the screen
/// because that is where the eye already is.
///
/// The trap: the results view is flipped (origin at the top left), because a
/// list that grows downwards is easier to reason about than one whose rows
/// renumber themselves as it grows. Rects from `row` are therefore top-down and
/// are only correct inside a view that says `isFlipped`.
enum PanelLayout {

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 62
    static let rowHeight: CGFloat = 54
    static let corner: CGFloat = 16
    static let margin: CGFloat = 18
    static let iconSize: CGFloat = 32

    /// A separator's worth of air between the field and the first row.
    static let divider: CGFloat = 1

    /// The strip along the bottom that says what the keys do. A panel with six
    /// shortcuts and no menu bar has nowhere else to say it, and a shortcut
    /// nobody can discover is a shortcut nobody uses.
    static let footerHeight: CGFloat = 24

    /// How tall the whole panel is with `rows` results showing. With none, it
    /// is a bare field: there is nothing to act on, so there are no keys to
    /// advertise.
    static func height(rows: Int) -> CGFloat {
        rows == 0 ? fieldHeight
                  : fieldHeight + divider + CGFloat(rows) * rowHeight + footerHeight
    }

    /// The footer, in the flipped coordinates of the results view.
    static func footer(rows: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: divider + CGFloat(rows) * rowHeight,
               width: width, height: footerHeight)
    }

    /// Where the panel sits on a screen. Horizontally centred, and a third of
    /// the way down rather than halfway, so a growing list does not push the
    /// field around under the cursor.
    static func frame(on screen: CGRect, rows: Int) -> CGRect {
        let h = height(rows: rows)
        let x = screen.midX - width / 2
        let top = screen.minY + screen.height * 0.72
        return CGRect(x: x.rounded(), y: (top - h).rounded(), width: width, height: h)
    }

    /// One result row, in the flipped coordinates of the results view.
    static func row(_ index: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
    }

    static func icon(in row: CGRect) -> CGRect {
        CGRect(x: row.minX + margin,
               y: row.midY - iconSize / 2,
               width: iconSize, height: iconSize)
    }

    /// Title and subtitle share a column that starts after the icon and stops
    /// short of the badge.
    static func text(in row: CGRect, badge: CGFloat) -> (title: CGRect, subtitle: CGRect) {
        let x = row.minX + margin + iconSize + 12
        let right = row.maxX - margin - badge - 12
        let w = max(40, right - x)
        return (CGRect(x: x, y: row.minY + 8, width: w, height: 19),
                CGRect(x: x, y: row.minY + 27, width: w, height: 16))
    }

    static func badge(in row: CGRect, width: CGFloat) -> CGRect {
        CGRect(x: row.maxX - margin - width, y: row.midY - 9, width: width, height: 18)
    }

    /// The tinted rectangle behind the selected row, inset so it reads as a
    /// pill inside the panel rather than a stripe across it.
    static func selection(in row: CGRect) -> CGRect {
        row.insetBy(dx: 8, dy: 3)
    }
}
