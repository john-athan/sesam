import Foundation
import CoreGraphics

/// The panel's arithmetic, checked without opening a window. 📐
func runPanelTests() {

    let screen = CGRect(x: 0, y: 0, width: 1512, height: 916)

    Check.suite("height follows the row count") {
        Check.equal(PanelLayout.height(rows: 0), PanelLayout.fieldHeight,
                    "with no results the panel is just the field")
        Check.that(PanelLayout.height(rows: 3) > PanelLayout.height(rows: 2),
                   "each row makes it taller")
        Check.equal(PanelLayout.height(rows: 8) - PanelLayout.height(rows: 7),
                    PanelLayout.rowHeight, "by exactly one row")
    }

    Check.suite("the frame stays on the screen") {
        for rows in 0...8 {
            let frame = PanelLayout.frame(on: screen, rows: rows)
            Check.that(frame.minX >= screen.minX && frame.maxX <= screen.maxX,
                       "\(rows) rows: horizontally inside the screen")
            Check.that(frame.minY >= screen.minY && frame.maxY <= screen.maxY,
                       "\(rows) rows: vertically inside the screen")
        }
    }

    Check.suite("the legend is there when there is something to act on") {
        Check.equal(PanelLayout.height(rows: 0), PanelLayout.fieldHeight,
                    "an empty search has no keys to advertise")
        Check.equal(PanelLayout.height(rows: 1),
                    PanelLayout.fieldHeight + PanelLayout.divider
                        + PanelLayout.rowHeight + PanelLayout.footerHeight,
                    "one result brings the footer with it")
        let footer = PanelLayout.footer(rows: 3, width: PanelLayout.width)
        let last = PanelLayout.row(2, width: PanelLayout.width)
            .offsetBy(dx: 0, dy: PanelLayout.divider)
        Check.equal(footer.minY, last.maxY, "and it sits directly under the last row")
    }

    Check.suite("the field does not move as the list grows") {
        let short = PanelLayout.frame(on: screen, rows: 1)
        let long = PanelLayout.frame(on: screen, rows: 8)
        Check.equal(short.maxY, long.maxY, "the panel grows downwards, from a fixed top")
    }

    Check.suite("rows stack, top down, without gaps") {
        let first = PanelLayout.row(0, width: PanelLayout.width)
        let second = PanelLayout.row(1, width: PanelLayout.width)
        Check.equal(first.maxY, second.minY, "one row starts where the last one ended")
        Check.that(PanelLayout.icon(in: first).minY >= first.minY,
                   "the icon is inside its row")
        let text = PanelLayout.text(in: first, badge: 40)
        Check.that(text.title.maxX <= first.maxX - PanelLayout.margin - 40,
                   "the title stops before the badge")
        Check.that(text.subtitle.minY > text.title.minY,
                   "the subtitle is below the title, in flipped coordinates")
    }

    Check.suite("the tile colour is the same after a restart") {
        Check.equal(PanelTheme.tile(for: "GitHub"), PanelTheme.tile(for: "github"),
                    "case does not change an entry's colour")
        Check.that(PanelTheme.tile(for: "GitHub") != PanelTheme.tile(for: "GitLab"),
                   "two neighbours usually differ")
    }
}
