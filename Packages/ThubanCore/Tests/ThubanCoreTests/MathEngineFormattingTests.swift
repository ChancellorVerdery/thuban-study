import XCTest
@testable import ThubanCore

/// Pure-Swift pieces of the MathEngine: the seeded generator and placeholder formatting. No JavaScript involved.
final class MathEngineFormattingTests: XCTestCase {

    // MARK: - SeededRandom

    func testSplitMixIsDeterministic() {
        var a = SeededRandom(seed: "deadbeef")
        var b = SeededRandom(seed: "deadbeef")
        for _ in 0..<32 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testSplitMixKnownValue() {
        // SplitMix64 reference output for state 0.
        var rng = SeededRandom(state: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
    }

    func testDifferentSeedsDiverge() {
        var a = SeededRandom(seed: "00000001")
        var b = SeededRandom(seed: "00000002")
        XCTAssertNotEqual(a.next(), b.next())
    }

    func testNonHexSeedsStillSeedDeterministically() {
        XCTAssertEqual(SeededRandom.state(fromSeed: "hello world"), SeededRandom.state(fromSeed: "hello world"))
        XCTAssertNotEqual(SeededRandom.state(fromSeed: "hello"), SeededRandom.state(fromSeed: "hellp"))
        XCTAssertEqual(SeededRandom.state(fromSeed: "ff"), 255)
    }

    func testRangesAreRespected() {
        var rng = SeededRandom(seed: "0badf00d")
        for _ in 0..<200 {
            XCTAssertTrue((-3...3).contains(rng.nextInt(in: -3...3)))
            let d = rng.nextDouble(in: 0.5...4)
            XCTAssertTrue(d >= 0.5 && d <= 4)
            let u = rng.nextUnit()
            XCTAssertTrue(u >= 0 && u < 1)
        }
    }

    func testNewSeedStringIsEightHexCharacters() {
        let seed = SeededRandom.newSeedString()
        XCTAssertEqual(seed.count, 8)
        XCTAssertNotNil(UInt32(seed, radix: 16))
    }

    // MARK: - TemplateFormatting

    private func sub(_ text: String, _ values: [String: TemplateValue]) -> String {
        TemplateFormatting.substitute(text, values: values)
    }

    func testPlainSubstitution() {
        XCTAssertEqual(sub("{a} + {b}", ["a": .int(3), "b": .int(4)]), "3 + 4")
        XCTAssertEqual(sub("f({v})", ["v": .choice("t")]), "f(t)")
    }

    func testUnknownPlaceholdersAndLatexBracesAreUntouched() {
        XCTAssertEqual(sub("\\frac{1}{2} + {q}", ["a": .int(3)]), "\\frac{1}{2} + {q}")
        XCTAssertEqual(sub("x^{2}", ["a": .int(3)]), "x^{2}")
    }

    func testNegativeAfterPlusFoldsTheSign() {
        XCTAssertEqual(sub("3x + {a}", ["a": .int(-3)]), "3x - 3")
        XCTAssertEqual(sub("3x+{a}", ["a": .int(-3)]), "3x-3")
    }

    func testNegativeAfterMinusFlipsTheSign() {
        XCTAssertEqual(sub("3x - {a}", ["a": .int(-3)]), "3x + 3")
    }

    func testNegativeAfterMultiplicationIsParenthesised() {
        XCTAssertEqual(sub("2 \\cdot {a}", ["a": .int(-3)]), "2 \\cdot (-3)")
        XCTAssertEqual(sub("2 \\times {a}", ["a": .int(-3)]), "2 \\times (-3)")
        XCTAssertEqual(sub("x{a}", ["a": .int(-3)]), "x(-3)")
        XCTAssertEqual(sub("2/{a}", ["a": .int(-3)]), "2/(-3)")
    }

    func testNegativeAtStartOrAfterOpeningIsBare() {
        XCTAssertEqual(sub("{a}x + 1", ["a": .int(-3)]), "-3x + 1")
        XCTAssertEqual(sub("y = {a}", ["a": .int(-3)]), "y = -3")
        XCTAssertEqual(sub("f({a})", ["a": .int(-3)]), "f(-3)")
        XCTAssertEqual(sub("$ {a} $", ["a": .int(-3)]), "$ -3 $")
        XCTAssertEqual(sub("\\frac{{a}}{2}", ["a": .int(-3)]), "\\frac{-3}{2}")
    }

    func testExponentsAreBraced() {
        XCTAssertEqual(sub("x^{a}", ["a": .int(-3)]), "x^{-3}")
        XCTAssertEqual(sub("x^{a}", ["a": .int(3)]), "x^{3}")
        XCTAssertEqual(sub("x_{i}", ["i": .int(2)]), "x_{2}")
    }

    func testCoefficientOneIsDropped() {
        XCTAssertEqual(sub("{a}x^2", ["a": .int(1)]), "x^2")
        XCTAssertEqual(sub("{a}x^2", ["a": .int(-1)]), "-x^2")
        XCTAssertEqual(sub("2 + {a}x", ["a": .int(1)]), "2 + x")
        XCTAssertEqual(sub("2 + {a}x", ["a": .int(-1)]), "2 - x")
        XCTAssertEqual(sub("2 - {a}x", ["a": .int(-1)]), "2 + x")
        XCTAssertEqual(sub("{a}\\sqrt{2}", ["a": .int(1)]), "\\sqrt{2}")
        XCTAssertEqual(sub("{a}(x+1)", ["a": .int(1)]), "(x+1)")
    }

    func testCoefficientOneIsKeptWhenNotACoefficient() {
        XCTAssertEqual(sub("y = {a}", ["a": .int(1)]), "y = 1")
        XCTAssertEqual(sub("{a} + x", ["a": .int(1)]), "1 + x")
        XCTAssertEqual(sub("{a} \\cdot x", ["a": .int(1)]), "1 \\cdot x")
    }

    func testRealRendering() {
        XCTAssertEqual(TemplateFormatting.render(2.5, decimals: 2), "2.5")
        XCTAssertEqual(TemplateFormatting.render(3.0, decimals: 1), "3")
        XCTAssertEqual(TemplateFormatting.render(-0.25, decimals: 2), "-0.25")
        XCTAssertEqual(TemplateFormatting.render(-0.0001, decimals: 2), "0")
        XCTAssertEqual(TemplateValue.real(1.5, decimals: 1).rendered, "1.5")
        XCTAssertEqual(sub("{r}x", ["r": .real(-1.5, decimals: 1)]), "-1.5x")
        XCTAssertEqual(sub("{r}x", ["r": .real(1.0, decimals: 1)]), "x")
    }

    func testPlaceholderNames() {
        XCTAssertEqual(TemplateFormatting.placeholderNames(in: "{a}x + {b_1} \\frac{1}{2}"), ["a", "b_1"])
    }

    func testSamplerHonoursExclusions() throws {
        var rng = SeededRandom(seed: "00000001")
        let params = [
            TemplateParam(name: "a", kind: .int(min: -1, max: 1), exclude: [0]),
            TemplateParam(name: "c", kind: .choice(["x"])),
        ]
        for _ in 0..<50 {
            let values = try TemplateSampler.draw(params, using: &rng)
            XCTAssertNotEqual(values["a"]?.numeric, 0)
            XCTAssertEqual(values["c"], .choice("x"))
        }
    }

    func testSamplerRejectsImpossibleExclusions() {
        var rng = SeededRandom(seed: "00000001")
        let params = [TemplateParam(name: "a", kind: .int(min: 1, max: 1), exclude: [1])]
        XCTAssertThrowsError(try TemplateSampler.draw(params, using: &rng)) { error in
            guard case ThubanError.invalidTemplate(let problems)? = error as? ThubanError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(problems.count, 1)
        }
    }
}
