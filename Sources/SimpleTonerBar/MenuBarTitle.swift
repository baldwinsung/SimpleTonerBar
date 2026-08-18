
import AppKit

/// Draws the menu bar reading: one rounded bubble per supply, each holding a
/// color dot and its percentage.
///
/// Colors are semantic (`labelColor`), and the image defers its drawing, so the
/// bubbles resolve against whichever appearance the menu bar is using at draw
/// time and follow a light/dark switch without a repoll.
enum MenuBarTitle {

    struct Reading {
        let color: NSColor
        /// Percentage, or "?" when the printer reports an indeterminate level.
        let text: String
    }

    private static let dotSize: CGFloat = 7
    /// Gap between the color dot and its number.
    private static let dotTextGap: CGFloat = 4
    private static let paddingH: CGFloat = 5
    private static let paddingV: CGFloat = 2
    private static let bubbleGap: CGFloat = 4

    static func font() -> NSFont {
        // Monospaced digits keep the bubbles from resizing as levels tick down.
        NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    }

    static func image(for readings: [Reading]) -> NSImage? {
        guard !readings.isEmpty else { return nil }

        let font = font()
        let widths = readings.map { reading -> CGFloat in
            let textWidth = ceil((reading.text as NSString).size(withAttributes: [.font: font]).width)
            return paddingH + dotSize + dotTextGap + textWidth + paddingH
        }

        let height = ceil(font.ascender - font.descender) + paddingV * 2
        let width = widths.reduce(0, +) + bubbleGap * CGFloat(readings.count - 1)

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0

            for (index, reading) in readings.enumerated() {
                let bubble = NSRect(x: x, y: 0, width: widths[index], height: height)
                // Inset by half a line width so the stroke isn't clipped at the edge.
                let outline = NSBezierPath(
                    roundedRect: bubble.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: height / 2,
                    yRadius: height / 2
                )
                NSColor.labelColor.withAlphaComponent(0.14).setFill()
                outline.fill()
                outline.lineWidth = 1
                NSColor.labelColor.withAlphaComponent(0.18).setStroke()
                outline.stroke()

                let dotRect = NSRect(
                    x: bubble.minX + paddingH,
                    y: (height - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                let dot = NSBezierPath(ovalIn: dotRect)
                reading.color.setFill()
                dot.fill()
                // Without this, black toner vanishes on a dark menu bar and white
                // on a light one.
                dot.lineWidth = 0.5
                NSColor.labelColor.withAlphaComponent(0.35).setStroke()
                dot.stroke()

                (reading.text as NSString).draw(
                    at: NSPoint(x: dotRect.maxX + dotTextGap, y: paddingV),
                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
                )

                x = bubble.maxX + bubbleGap
            }

            return true
        }
    }
}
