import CoreGraphics
import XCTest
@testable import ThubanCore

/// Watermarks come off a page picture; figures are found on it (never the whole page).
final class PageCleanupTests: XCTestCase {
    /// A page with black text, a coloured diagram block and a light-grey diagonal watermark band.
    private func syntheticPage() -> CGImage {
        let w = 600, h = 800
        let context = ImageCodec.rgbaContext(width: w, height: h)!
        // Watermark: a wide light-grey band across the page.
        context.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 380, width: w, height: 60))
        // Running text: dark lines.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for row in 0..<6 { context.fill(CGRect(x: 40, y: 700 - row * 18, width: 520, height: 8)) }
        // A diagram: outlined, colour-filled box with a line.
        context.setFillColor(CGColor(red: 0.6, green: 0.8, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 150, y: 150, width: 300, height: 180))
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(3)
        context.stroke(CGRect(x: 150, y: 150, width: 300, height: 180))
        return context.makeImage()!
    }

    func testWatermarkGreyIsWipedButInkAndColourStay() throws {
        var bitmap = try XCTUnwrap(PageBitmap(syntheticPage()))
        let wiped = WatermarkRemover.clean(&bitmap)
        XCTAssertGreaterThan(wiped, 0.05)
        // Rows are top-down: the band at y 380–440 from the bottom is at 360–420 from the top.
        let band = 390 * bitmap.width + 20
        XCTAssertEqual(bitmap.luminance(band), 255, "watermark grey is gone")
        let text = (800 - 704) * bitmap.width + 100
        XCTAssertLessThan(bitmap.luminance(text), 60, "text stays")
        let fill = (800 - 240) * bitmap.width + 300
        XCTAssertGreaterThan(bitmap.chroma(fill), 30, "colour fill stays")
    }

    func testFigureIsFoundAndTextIsNot() throws {
        var bitmap = try XCTUnwrap(PageBitmap(syntheticPage()))
        WatermarkRemover.clean(&bitmap)
        // Running text lines (as OCR would report them) and a caption under the diagram.
        var lines = (0..<6).map { row in TextLine(text: "Running text line \(row)", rect: CGRect(x: 40, y: 88 + Double(row * 18), width: 520, height: 12)) }
        lines.append(TextLine(text: "FIGURE P1.28", rect: CGRect(x: 250, y: 660, width: 100, height: 14)))
        let found = PageFigureFinder.figures(in: bitmap, lines: lines)
        XCTAssertEqual(found.count, 1, "\(found)")
        let rect = try XCTUnwrap(found.first?.rect)
        // The diagram sits at y 470–650 from the top.
        XCTAssertLessThan(abs(rect.minY - 470), 20)
        XCTAssertLessThan(abs(rect.maxY - 650), 20)
        XCTAssertLessThan(rect.width, 400, "not the whole page")
        XCTAssertEqual(found.first?.caption, "FIGURE P1.28")
    }

    /// `THUBAN_PAGE_FIGURES=<pdf>` and `THUBAN_PAGE_FIGURES_OUT=<dir>`: parse a real PDF and write each cleaned page and
    /// each figure found, for a visual check.
    func testWritesPagesAndFiguresForARealPDF() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["THUBAN_PAGE_FIGURES"], let out = env["THUBAN_PAGE_FIGURES_OUT"] else {
            throw XCTSkip("Set THUBAN_PAGE_FIGURES and THUBAN_PAGE_FIGURES_OUT to run.")
        }
        let content = try await PDFParser().parse(url: URL(fileURLWithPath: path))
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (page, png) in content.pageImages { try png.write(to: dir.appendingPathComponent("page-\(page).png")) }
        var report = ["pages \(content.pageCount), figures \(content.figures.count)"]
        for figure in content.figures {
            try figure.pngData.write(to: dir.appendingPathComponent("figure-\(figure.page ?? 0)-\(figure.index).png"))
            report.append("figure \(figure.index) page \(figure.page ?? 0): \(figure.nearbyText.prefix(60).replacingOccurrences(of: "\n", with: " | "))")
        }
        report.append("text sample: " + content.fullText.prefix(400).replacingOccurrences(of: "\n", with: " | "))
        try report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
