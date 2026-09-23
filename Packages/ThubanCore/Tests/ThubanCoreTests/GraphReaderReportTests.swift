import XCTest
@testable import ThubanCore

/// Development report: runs the graph reader over every image in `$THUBAN_FIGURE_DIR` and prints what it found
/// (axes, calibration, curves). Skipped unless the variable is set; it asserts nothing.
final class GraphReaderReportTests: XCTestCase {
    func testReportOnFigureDirectory() async throws {
        guard let directory = ProcessInfo.processInfo.environment["THUBAN_FIGURE_DIR"] else {
            throw XCTSkip("set THUBAN_FIGURE_DIR to a folder of figure images")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".gif") || $0.hasSuffix(".png") }.sorted()
        var lines: [String] = []
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(file))
            if ProcessInfo.processInfo.environment["THUBAN_FIGURE_PHASE"] != nil {
                let phase = await PhaseLineReader.read(png: data)
                lines.append("\(file): phase \(phase.map { "marks \($0.marks.map { "\($0.text)@\($0.position)" }) arrows \($0.arrows.map { "\($0.increasing ? "up" : "down")@\($0.position)" })" } ?? "none")")
                if ProcessInfo.processInfo.environment["THUBAN_FIGURE_DIAGNOSE"] != nil { lines.append("    " + (await GraphReader.diagnose(png: data))) }
                continue
            }
            guard let reading = await GraphReader.read(png: data) else {
                lines.append("\(file): no reading — \(await GraphReader.diagnose(png: data))")
                continue
            }
            let xr = reading.x.range, yr = reading.y.range
            var line = "\(file): \(reading.width)x\(reading.height) origin(col \(Int(reading.originColumn)), row \(Int(reading.originRow)))"
            line += " x[\(fmt(xr.lowerBound))…\(fmt(xr.upperBound))] labels \(reading.x.labelCount)"
            line += " y[\(fmt(yr.lowerBound))…\(fmt(yr.upperBound))] labels \(reading.y.labelCount)"
            if let c = reading.fieldColumns, let r = reading.fieldRows { line += " field \(c)x\(r)" }
            line += " xl \(reading.xTickLabels.map(\.text)) yl \(reading.yTickLabels.map(\.text))"
            line += " curves: " + reading.curves.map { "\($0.color)(\($0.pixelCount)px, \($0.points.count)pts, x \(fmt($0.points.first?[0] ?? .nan))…\(fmt($0.points.last?[0] ?? .nan)), y@0 \(fmt(yAtZero($0)))" }.joined(separator: "; ")
            if ProcessInfo.processInfo.environment["THUBAN_FIGURE_DIAGNOSE"] != nil { line += "\n    " + (await GraphReader.diagnose(png: data)) }
            lines.append(line)
        }
        let report = lines.joined(separator: "\n")
        print("GRAPH READER REPORT\n" + report)
        try report.write(toFile: directory + "/report.txt", atomically: true, encoding: .utf8)
    }

    private func yAtZero(_ curve: GraphReading.Curve) -> Double {
        // Linear interpolation of the polyline at x = 0.
        let pts = curve.points
        guard pts.count >= 2 else { return .nan }
        for i in 1..<pts.count where (pts[i - 1][0] <= 0 && pts[i][0] >= 0) {
            let a = pts[i - 1], b = pts[i]
            guard b[0] > a[0] else { return b[1] }
            return a[1] + (0 - a[0]) / (b[0] - a[0]) * (b[1] - a[1])
        }
        return .nan
    }

    private func fmt(_ v: Double) -> String { v.isNaN ? "–" : String(format: "%.2f", v) }
}
