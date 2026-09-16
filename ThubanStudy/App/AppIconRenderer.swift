import AppKit
import SwiftUI
import ThubanCore

/// Draws the dock icon from the theme: a 1024 px squircle plate (`bg`) with the Thuban mark stroked in `accent`.
enum AppIconRenderer {
    static let canvasSize: CGFloat = 1024
    /// macOS icon grid: the plate is 824 px inside the 1024 canvas.
    static let plateSize: CGFloat = 824
    /// Continuous-corner radius that matches the system squircle closely enough.
    static let plateRadius: CGFloat = 824 * 0.2237

    private static var lastKey: String?

    /// Sets `NSApp.applicationIconImage` for the theme (no-op when nothing changed).
    @MainActor
    static func apply(theme: ResolvedTheme) {
        let key = theme.bg + theme.accent + theme.line2
        guard key != lastKey else { return }
        lastKey = key
        NSApplication.shared.applicationIconImage = render(theme: theme)
        if let path = ProcessInfo.processInfo.environment["THUBAN_DUMP_ICON"] {
            dump(theme: theme, to: URL(fileURLWithPath: path))
        }
    }

    /// Renders the icon at 1024×1024 points.
    static func render(theme: ResolvedTheme, size: CGFloat = canvasSize) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(theme: theme, in: rect)
            return true
        }
        return image
    }

    static func draw(theme: ResolvedTheme, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / canvasSize
        let plate = CGRect(
            x: rect.minX + (canvasSize - plateSize) / 2 * scale,
            y: rect.minY + (canvasSize - plateSize) / 2 * scale,
            width: plateSize * scale,
            height: plateSize * scale
        )
        let platePath = CGPath(roundedRect: plate, cornerWidth: plateRadius * scale, cornerHeight: plateRadius * scale, transform: nil)
        context.saveGState()
        context.addPath(platePath)
        context.setFillColor(NSColor(hex: theme.bg).cgColor)
        context.fillPath()
        // Hairline rim so a light plate still reads on a light desktop.
        context.addPath(platePath)
        context.setStrokeColor(NSColor(hex: theme.line2).withAlphaComponent(0.6).cgColor)
        context.setLineWidth(6 * scale)
        context.strokePath()
        context.restoreGState()

        // The mark, centred, filling ~62% of the plate.
        let markSize = plate.width * 0.62
        let markRect = CGRect(x: plate.midX - markSize / 2, y: plate.midY - markSize / 2, width: markSize, height: markSize)
        let markPath = ThubanMark().path(in: markRect).cgPath
        let style = ThubanMark.strokeStyle(size: markSize)
        context.saveGState()
        context.addPath(markPath)
        context.setStrokeColor(NSColor(hex: theme.accent).cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// Debug helper: writes a 512 px PNG (`THUBAN_DUMP_ICON=/path.png`).
    static func dump(theme: ResolvedTheme, to url: URL) {
        let image = render(theme: theme, size: 512)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
