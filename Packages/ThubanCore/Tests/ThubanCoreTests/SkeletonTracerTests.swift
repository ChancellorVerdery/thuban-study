import XCTest
@testable import ThubanCore

/// Thick synthetic strokes traced back into ordered paths: closed loops, open curves, a loop through its own
/// crossing, a curve cut by an erased arrowhead, and two lines crossing.
final class SkeletonTracerTests: XCTestCase {
    typealias Point = SkeletonTracer.Point

    /// The curve sampled densely over `t`.
    func curve(_ t: ClosedRange<Double>, _ f: (Double) -> Point) -> [Point] {
        let n = 4000
        return (0...n).map { f(t.lowerBound + (t.upperBound - t.lowerBound) * Double($0) / Double(n)) }
    }

    /// The pixels within half a stroke of the curve.
    func stroke(_ curve: [Point], width: Double = 3.5) -> Set<[Int]> {
        let r = width / 2
        var pixels = Set<[Int]>()
        for p in curve {
            for c in Int((p.0 - r).rounded(.down))...Int((p.0 + r).rounded(.up)) {
                for row in Int((p.1 - r).rounded(.down))...Int((p.1 + r).rounded(.up)) where hypot(Double(c) - p.0, Double(row) - p.1) <= r {
                    pixels.insert([c, row])
                }
            }
        }
        return pixels
    }

    func trace(_ pixels: Set<[Int]>, erasing blobs: [SkeletonTracer.Blob] = []) -> [[Point]] {
        SkeletonTracer.paths(of: pixels.map { ($0[0], $0[1]) }, erasing: blobs)
    }

    func farthest(_ path: [Point], from curve: [Point]) -> Double {
        path.map { p in curve.map { hypot($0.0 - p.0, $0.1 - p.1) }.min()! }.max()!
    }

    func testACircleIsOneClosedPath() throws {
        let circle = curve(0...(2 * .pi)) { (60 + 40 * cos($0), 60 + 40 * sin($0)) }
        let paths = trace(stroke(circle))
        XCTAssertEqual(paths.count, 1)
        let path = try XCTUnwrap(paths.first)
        XCTAssertEqual(path.first!.0, path.last!.0, accuracy: 1e-9, "closed")
        XCTAssertEqual(path.first!.1, path.last!.1, accuracy: 1e-9, "closed")
        for p in path { XCTAssertEqual(hypot(p.0 - 60, p.1 - 60), 40, accuracy: 1.5) }
        XCTAssertEqual(SkeletonTracer.length(path), 2 * .pi * 40, accuracy: 2 * .pi * 40 * 0.05, "all the way round")
    }

    func testAParabolaIsOneOpenPath() throws {
        let parabola = curve(10...110) { ($0, 100 - ($0 - 60) * ($0 - 60) / 40) }
        let paths = trace(stroke(parabola))
        XCTAssertEqual(paths.count, 1)
        let path = try XCTUnwrap(paths.first)
        XCTAssertGreaterThan(hypot(path.first!.0 - path.last!.0, path.first!.1 - path.last!.1), 80, "open, end to end")
        XCTAssertLessThan(farthest(path, from: parabola), 1.5)
        XCTAssertEqual(SkeletonTracer.length(path), SkeletonTracer.length(parabola), accuracy: SkeletonTracer.length(parabola) * 0.1)
    }

    func testALoopRunsStraightThroughItsCrossing() throws {
        // x = t², y = t³ − 3t crosses itself at t = ±√3.
        let loop = curve(-2.2...2.2) { (20 + 18 * $0 * $0, 80 - 18 * ($0 * $0 * $0 - 3 * $0)) }
        let paths = trace(stroke(loop))
        XCTAssertEqual(paths.count, 1, "one stroke through the crossing")
        let path = try XCTUnwrap(paths.first)
        let truth = SkeletonTracer.length(loop)
        XCTAssertEqual(SkeletonTracer.length(path), truth, accuracy: truth * 0.1)
        XCTAssertLessThan(farthest(path, from: loop), 2)
    }

    func testAFigureEightIsOneClosedPath() throws {
        let eight = curve(0...(2 * .pi)) { (80 + 60 * sin($0), 50 + 35 * sin(2 * $0)) }
        let paths = trace(stroke(eight, width: 4))
        XCTAssertEqual(paths.count, 1)
        let path = try XCTUnwrap(paths.first)
        XCTAssertEqual(hypot(path.first!.0 - path.last!.0, path.first!.1 - path.last!.1), 0, accuracy: 1e-9, "closed")
        XCTAssertLessThan(farthest(path, from: eight), 2)
        XCTAssertEqual(SkeletonTracer.length(path), SkeletonTracer.length(eight), accuracy: SkeletonTracer.length(eight) * 0.1)
    }

    func testAnErasedArrowheadLeavesOneSmoothPath() throws {
        let wave = curve(10...190) { ($0, 60 + 20 * sin($0 / 25)) }
        var pixels = stroke(wave)
        // A filled arrowhead on the curve at x = 100, pointing along it.
        let tip: Point = (100, 60 + 20 * sin(4))
        let slope = 20.0 / 25 * cos(4.0), norm = hypot(1, slope)
        let along: Point = (1 / norm, slope / norm), across: Point = (-along.1, along.0)
        for i in 0...24 { for j in -12...12 {
            let back = Double(i) / 2, side = Double(j) / 2
            guard abs(side) <= back * 0.45 else { continue }
            pixels.insert([Int((tip.0 - along.0 * back + across.0 * side).rounded()), Int((tip.1 - along.1 * back + across.1 * side).rounded())])
        } }
        let centre: Point = (tip.0 - along.0 * 6, tip.1 - along.1 * 6)
        let paths = trace(pixels, erasing: [(x: centre.0, y: centre.1, radius: 8)])
        XCTAssertEqual(paths.count, 1, "joined across the arrowhead")
        let path = try XCTUnwrap(paths.first)
        XCTAssertLessThan(farthest(path, from: wave), 2)
        XCTAssertGreaterThan(abs(path.last!.0 - path.first!.0), 170, "end to end")
    }

    func testTwoCrossingLinesStayTwoStraightPaths() {
        let down = curve(0...1) { (10 + 100 * $0, 10 + 100 * $0) }, up = curve(0...1) { (10 + 100 * $0, 110 - 100 * $0) }
        let paths = trace(stroke(down).union(stroke(up)))
        XCTAssertEqual(paths.count, 2)
        for path in paths {
            let line = farthest(path, from: down) < farthest(path, from: up) ? down : up
            XCTAssertLessThan(farthest(path, from: line), 1.5, "straight along one line")
            XCTAssertGreaterThan(SkeletonTracer.length(path), 125, "through the crossing")
        }
        XCTAssertNotEqual(farthest(paths[0], from: down) < 1.5, farthest(paths[1], from: down) < 1.5, "one path per line")
    }
}
