import XCTest
@testable import ThubanCore

/// Development harness: runs the picture check on every stored chart in a folder of fixtures
/// (`FIXTURE_SWEEP_DIR` holding `<n>.json` and `<n>.png`) and prints one line per figure. Skipped unless set.
final class FixtureSweepReportTests: XCTestCase {
    private func say(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    func testSweep() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FIXTURE_SWEEP_DIR"] else { throw XCTSkip("set FIXTURE_SWEEP_DIR") }
        let engine = MathEngine()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
        let after = ProcessInfo.processInfo.environment["FIXTURE_SWEEP_AFTER"] ?? ""
        let only = Set((ProcessInfo.processInfo.environment["FIXTURE_SWEEP_ONLY"] ?? "").split(separator: " ").map(String.init))
        for name in names where String(name.dropLast(5)) > after && (only.isEmpty || only.contains(String(name.dropLast(5)))) {
            let base = String(name.dropLast(5))
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let chart = try? JSONDecoder().decode(StandardChart.self, from: data),
                  let png = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(base + ".png")) else {
                say("SWEEP \(base) no chart"); continue
            }
            say("SWEEP-START \(base)")
            let checked = await FigureAgent.check(chart, png: png, engine: engine)
            let marks = checked.series.filter { $0.seriesKind == .vector || $0.seriesKind == .point }.map { "\($0.kind ?? ""):\($0.points ?? [])" }
            let curves = checked.series.compactMap(\.latex)
            say("SWEEP \(base) \(checked.verification?.passed == true ? "PASS" : "FAIL") | \(checked.verification?.summary ?? "-") | marks \(marks) | curves \(curves) | hues \(checked.series.map { "\($0.hue.map { Int($0) } ?? -1)/\($0.vectorHue.map { Int($0) } ?? -1)" })")
        }
    }
}
