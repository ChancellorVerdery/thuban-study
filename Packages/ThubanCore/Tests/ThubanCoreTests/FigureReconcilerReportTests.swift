import XCTest
@testable import ThubanCore

/// Development report: for every `N.png` + `N.json` (a stored `StandardChart`) pair in `$THUBAN_RECONCILE_DIR`,
/// reconciles the chart against the picture and prints what changed. Skipped unless the variable is set.
final class FigureReconcilerReportTests: XCTestCase {
    func testReportOnStoredCharts() async throws {
        guard let directory = ProcessInfo.processInfo.environment["THUBAN_RECONCILE_DIR"] else {
            throw XCTSkip("set THUBAN_RECONCILE_DIR to a folder of N.png + N.json pairs")
        }
        let engine = MathEngine()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
        var lines: [String] = []
        for file in files {
            let base = String(file.dropLast(5))
            let url = URL(fileURLWithPath: directory)
            guard let png = try? Data(contentsOf: url.appendingPathComponent(base + ".png")),
                  let json = try? Data(contentsOf: url.appendingPathComponent(file)),
                  let chart = try? JSONDecoder().decode(StandardChart.self, from: json) else { lines.append("\(base): unreadable"); continue }
            let before = describe(chart)
            let checked = await FigureAgent.check(chart, png: png, engine: engine)
            lines.append("\(base):\n   before: \(before)\n   after:  \(describe(checked))\n   verify: \(checked.verification.map { ($0.passed ? "PASS " : "FAIL ") + $0.summary } ?? "none")")
        }
        let report = lines.joined(separator: "\n")
        print("RECONCILE REPORT\n" + report)
        try report.write(toFile: directory + "/report.txt", atomically: true, encoding: .utf8)
    }

    private func describe(_ chart: StandardChart) -> String {
        let series = chart.series.map { s -> String in
            var d = s.name
            if let latex = s.latex { d += " latex=\(latex)" }
            if let t = s.through { d += " through=\(t)" }
            if let p = s.points { d += " \(p.count)pts" }
            return d
        }.joined(separator: " | ")
        return "\(chart.chartType) prov=\(chart.provenance ?? "-") x=\(chart.xRange ?? []) y=\(chart.yRange ?? []) def=\(chart.definition ?? "-") series=[\(series)]"
    }
}
