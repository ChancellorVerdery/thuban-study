import SwiftUI

/// The app mark: a dragon coil (spiral body, serpentine neck) with a 4-point star at its head — Thuban, the old
/// pole star. Path from `docs/icons.md` (24×24 viewBox), meant to be STROKED (1.75/24 of the size, round caps).
struct ThubanMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        // Coil: M9 15 a1 1 0 0 1 1 1 a2 2 0 0 1-2 2 a3 3 0 0 1-3-3 a4 4 0 0 1 4-4 c3 0 4.5-.5 6-4
        // Each arc is a quarter circle turning clockwise on screen; in SwiftUI's flipped space that is `clockwise: false`.
        path.move(to: point(9, 15))
        path.addArc(center: point(9, 16), radius: 1 * scale, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addArc(center: point(8, 16), radius: 2 * scale, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addArc(center: point(8, 15), radius: 3 * scale, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addArc(center: point(9, 15), radius: 4 * scale, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addCurve(to: point(15, 7), control1: point(12, 11), control2: point(13.5, 10.5))
        // Star: M18 3.5 v4   M16 5.5 h4
        path.move(to: point(18, 3.5))
        path.addLine(to: point(18, 7.5))
        path.move(to: point(16, 5.5))
        path.addLine(to: point(20, 5.5))
        return path
    }

    /// Stroke style matching the icon set at a given rendered size.
    static func strokeStyle(size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.75 * size / 24, lineCap: .round, lineJoin: .round)
    }
}

/// The mark stroked in a color at a square size.
struct ThubanMarkView: View {
    var size: CGFloat = 20
    var color: Color

    var body: some View {
        ThubanMark()
            .stroke(color, style: ThubanMark.strokeStyle(size: size))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
