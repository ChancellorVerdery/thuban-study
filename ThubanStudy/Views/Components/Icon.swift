import SwiftUI

/// The twelve icons from `docs/icons.md`, shipped as template SVGs in `Assets.xcassets/Icons`.
enum IconName: String, CaseIterable {
    case thubanMark = "thuban-mark"
    case classTab = "class"
    case questionBank = "question-bank"
    case importDocs = "import"
    case tutor
    case graph2D = "graph-2d"
    case graph3D = "graph-3d"
    case calculator
    case mathKeyboard = "math-keyboard"
    case figureClip = "figure-clip"
    case mathEngine = "math-engine"
    case themePalette = "theme-palette"
}

/// A template icon at 16/18/20 pt, tinted with the current foreground style.
struct Icon: View {
    var name: IconName
    var size: CGFloat = 18

    init(_ name: IconName, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    /// Looks an icon up by its asset id ("graph-2d"); unknown ids draw nothing.
    init?(name: String, size: CGFloat = 18) {
        guard let icon = IconName(rawValue: name) else { return nil }
        self.name = icon
        self.size = size
    }

    var body: some View {
        Image(name.rawValue)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Minimal stroke glyphs the icon set does not include (plus, close, check, chevron, search, send, lock, drag, reset).
struct Glyph: View {
    enum Kind { case plus, close, check, chevronDown, chevronRight, chevronLeft, search, send, lock, dragHandle, dot, reset }
    var kind: Kind
    var size: CGFloat = 16

    init(_ kind: Kind, size: CGFloat = 16) {
        self.kind = kind
        self.size = size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var path = Path()
            switch kind {
            case .plus:
                path.move(to: p(12, 5)); path.addLine(to: p(12, 19))
                path.move(to: p(5, 12)); path.addLine(to: p(19, 12))
            case .close:
                path.move(to: p(6, 6)); path.addLine(to: p(18, 18))
                path.move(to: p(18, 6)); path.addLine(to: p(6, 18))
            case .check:
                path.move(to: p(5, 12.5)); path.addLine(to: p(10, 17.5)); path.addLine(to: p(19, 7))
            case .chevronDown:
                path.move(to: p(6, 9.5)); path.addLine(to: p(12, 15.5)); path.addLine(to: p(18, 9.5))
            case .chevronRight:
                path.move(to: p(9.5, 6)); path.addLine(to: p(15.5, 12)); path.addLine(to: p(9.5, 18))
            case .chevronLeft:
                path.move(to: p(14.5, 6)); path.addLine(to: p(8.5, 12)); path.addLine(to: p(14.5, 18))
            case .search:
                path.addEllipse(in: CGRect(x: 4 * s, y: 4 * s, width: 11 * s, height: 11 * s))
                path.move(to: p(13.5, 13.5)); path.addLine(to: p(20, 20))
            case .send:
                path.move(to: p(4, 12)); path.addLine(to: p(20, 4)); path.addLine(to: p(14, 20)); path.addLine(to: p(11.5, 12.5)); path.closeSubpath()
            case .lock:
                path.addRoundedRect(in: CGRect(x: 5 * s, y: 11 * s, width: 14 * s, height: 9.5 * s), cornerSize: CGSize(width: 2 * s, height: 2 * s))
                path.move(to: p(8, 11)); path.addLine(to: p(8, 8))
                path.addArc(center: p(12, 8), radius: 4 * s, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                path.addLine(to: p(16, 11))
            case .dragHandle:
                for y: CGFloat in [7, 12, 17] {
                    path.move(to: p(9, y)); path.addLine(to: p(9.01, y))
                    path.move(to: p(15, y)); path.addLine(to: p(15.01, y))
                }
            case .dot:
                path.addEllipse(in: CGRect(x: 8 * s, y: 8 * s, width: 8 * s, height: 8 * s))
            case .reset:
                // Counter-clockwise arc with an arrowhead at its start (the "reset view" convention).
                path.addArc(center: p(12, 12.5), radius: 7 * s, startAngle: .degrees(-150), endAngle: .degrees(120), clockwise: false)
                path.move(to: p(3.4, 4.5)); path.addLine(to: p(5.9, 9)); path.addLine(to: p(10.4, 7.2))
            }
            let style = StrokeStyle(lineWidth: (kind == .dragHandle ? 2.5 : 1.75) * s, lineCap: .round, lineJoin: .round)
            if kind == .dot {
                context.fill(path, with: .foreground)
            } else {
                context.stroke(path, with: .foreground, style: style)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
