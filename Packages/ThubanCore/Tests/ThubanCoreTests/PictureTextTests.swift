import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ThubanCore

/// Printed labels are read off a figure and attached to the chart drawn from it: a point's label, a vector's name,
/// stray text as annotations — never the axes' tick numbers or names.
final class PictureTextTests: XCTestCase {
    private let size = 600
    /// 30 pixels per unit with the origin at the picture's centre (rows grow downwards).
    private var reading: GraphReading {
        let x = GraphReading.AxisMap(origin: 300, scale: 30, labelCount: 0, extent: 20...580)
        let y = GraphReading.AxisMap(origin: 300, scale: -30, labelCount: 0, extent: 20...580)
        return GraphReading(width: size, height: size, x: x, y: y, curves: [])
    }

    private var chart: StandardChart {
        var point = ChartSeries(name: "A", points: [[-1, 4]])
        point.kind = "point"
        var vector = ChartSeries(name: "a", points: [[0, 0], [5, 1]], color: "#e02020")
        vector.kind = "vector"
        return StandardChart(chartType: "line", series: [point, vector])
    }

    /// White picture, black axes through the centre with a tick number "2" and the name "x", a dot at (−1, 4)
    /// labelled "A(-1, 4)", a red arrow from the origin to (5, 1) named "a", and a stray "60°" low on the left.
    private func syntheticPNG() throws -> Data {
        let context = try XCTUnwrap(ImageCodec.rgbaContext(width: size, height: size))
        let h = CGFloat(size)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(2)
        context.strokeLineSegments(between: [CGPoint(x: 20, y: h - 300), CGPoint(x: 580, y: h - 300),
                                             CGPoint(x: 300, y: h - 20), CGPoint(x: 300, y: h - 580)])
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 265, y: h - 185, width: 10, height: 10))
        context.setStrokeColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.setLineWidth(3)
        context.strokeLineSegments(between: [CGPoint(x: 300, y: h - 300), CGPoint(x: 450, y: h - 270)])
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.addLines(between: [CGPoint(x: 452, y: h - 270), CGPoint(x: 434, y: h - 262), CGPoint(x: 437, y: h - 280)])
        context.fillPath()
        draw("A(-1, 4)", at: CGPoint(x: 160, y: h - 190), in: context)
        draw("a", at: CGPoint(x: 462, y: h - 262), in: context)
        draw("60°", at: CGPoint(x: 130, y: h - 460), in: context)
        draw("2", at: CGPoint(x: 355, y: h - 325), in: context)
        draw("x", at: CGPoint(x: 560, y: h - 330), in: context)
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Draws `text` in black with its baseline starting at `point` (CoreGraphics coordinates).
    private func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    func testLabelsAreReadFromThePictureAndAttached() async throws {
        let words = await PictureText.words(in: try syntheticPNG())
        let texts = words.map(\.text)
        // Vision may or may not keep the space after the comma.
        XCTAssertTrue(texts.map(compact).contains("A(-1,4)"), "read: \(texts)")
        XCTAssertTrue(texts.contains("a"), "read: \(texts)")
        XCTAssertTrue(texts.contains("60°"), "read: \(texts)")

        let attached = PictureText.attach(chart, words: words, reading: reading, columns: 20...580, rows: 20...580)
        XCTAssertEqual(attached.series[0].labels?.map(compact), ["A(-1,4)"])
        XCTAssertEqual(attached.series[1].label, "a")
        let annotations = try XCTUnwrap(attached.annotations)
        XCTAssertEqual(annotations.map(\.text), ["60°"], "tick number and axis name are left out")
        XCTAssertEqual(annotations[0].x, -5, accuracy: 0.6)
        XCTAssertEqual(annotations[0].y, -5.1, accuracy: 0.6)
    }

    func testTextIsNeverAttachedTwice() {
        let words = [
            PictureText.Word(text: "A(-1, 4)", rect: CGRect(x: 160, y: 170, width: 95, height: 22)),
            PictureText.Word(text: "A(-1, 4)", rect: CGRect(x: 400, y: 400, width: 95, height: 22)),
            PictureText.Word(text: "a", rect: CGRect(x: 462, y: 245, width: 12, height: 14)),
            PictureText.Word(text: "a", rect: CGRect(x: 100, y: 100, width: 12, height: 14)),
        ]
        let attached = PictureText.attach(chart, words: words, reading: reading, columns: 20...580, rows: 20...580)
        XCTAssertEqual(attached.series[0].labels, ["A(-1, 4)"])
        XCTAssertEqual(attached.series[1].label, "a")
        XCTAssertNil(attached.annotations)
    }

    func testTickNumbersNearAnAxisAreNotLabels() {
        let tick = PictureText.Word(text: "−2", rect: CGRect(x: 270, y: 352, width: 20, height: 18))
        let stray = PictureText.Word(text: "16", rect: CGRect(x: 420, y: 120, width: 20, height: 18))
        XCTAssertTrue(PictureText.isTickNumber(tick, reading: reading))
        XCTAssertFalse(PictureText.isTickNumber(stray, reading: reading))
        // On a plot with axes a bare number standing alone is a misread, not a label: neither is kept.
        let attached = PictureText.attach(chart, words: [tick, stray], reading: reading, columns: 20...580, rows: 20...580)
        XCTAssertNil(attached.annotations)
    }
}
