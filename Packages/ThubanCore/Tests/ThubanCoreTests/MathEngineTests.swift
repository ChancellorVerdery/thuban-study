import XCTest
@testable import ThubanCore

/// Grading matrix for the MathEngine. One engine instance is shared across the file because loading the Compute
/// Engine bundle costs ~0.2 s.
final class MathEngineTests: XCTestCase {
    static let engine = MathEngine()

    struct Case {
        var name: String
        var student: String
        var expected: String
        var conditions: AnswerConditions = .none
        var alternatives: [String] = []
        var outcome: Verdict.Outcome
        var failed: [String] = []
    }

    // MARK: - Table-driven grading

    static let cases: [Case] = [
        // Equivalence of expressions
        Case(name: "2/4 x ≡ 1/2 x", student: "\\frac{2}{4}x", expected: "\\frac{1}{2}x", outcome: .correct),
        Case(name: "as equations y = …", student: "y=\\frac{2}{4}x", expected: "y=\\frac{1}{2}x", outcome: .correct),
        Case(name: "0.5 ≡ 1/2 exactly", student: "0.5", expected: "\\frac{1}{2}", outcome: .correct),
        Case(name: "1/2 ≡ 0.5 exactly", student: "\\frac{1}{2}", expected: "0.5", outcome: .correct),
        Case(name: "1/√2 ≡ √2/2", student: "\\frac{1}{\\sqrt{2}}", expected: "\\frac{\\sqrt{2}}{2}", outcome: .correct),
        Case(name: "(x+1)^2 ≡ x^2+2x+1", student: "(x+1)^2", expected: "x^2+2x+1", outcome: .correct),
        Case(name: "sin²x+cos²x ≡ 1", student: "\\sin^2 x + \\cos^2 x", expected: "1", outcome: .correct),
        Case(name: "28(x−1)+35(y−2)+22 ≡ 28x+35y−76", student: "28(x-1)+35(y-2)+22", expected: "28x+35y-76", outcome: .correct),
        Case(name: "0.25x ≡ x/4", student: "0.25x", expected: "\\frac{x}{4}", outcome: .correct),
        Case(name: "e^{2x} ≡ e^{2x}", student: "e^{2x}", expected: "e^{2x}", outcome: .correct),
        Case(name: "√(x²) ≡ |x|", student: "\\sqrt{x^2}", expected: "|x|", outcome: .correct),
        Case(name: "ln(x²) ≡ 2 ln x on shared domain", student: "\\ln(x^2)", expected: "2\\ln x", outcome: .correct),
        Case(name: "derivative evaluates before comparing", student: "\\frac{d}{dx} x^2", expected: "2x", outcome: .correct),
        Case(name: "different constants", student: "x+1", expected: "x+2", outcome: .incorrect),
        Case(name: "different symbols", student: "x", expected: "y", outcome: .incorrect),
        Case(name: "alternative accepted", student: "x^2", expected: "x^3", alternatives: ["x^2"], outcome: .correct),

        // Exactness and rounding
        Case(name: "0.6247 vs 28/√2009 ⇒ exactForm", student: "0.6247", expected: "\\frac{28}{\\sqrt{2009}}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),
        Case(name: "0.62 with 2 decimals ⇒ correct", student: "0.62", expected: "\\frac{28}{\\sqrt{2009}}", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),
        Case(name: "0.63 with 2 decimals ⇒ incorrect", student: "0.63", expected: "\\frac{28}{\\sqrt{2009}}", conditions: AnswerConditions(roundingDecimals: 2), outcome: .incorrect),
        Case(name: "0.7 exact required ⇒ incorrect (not a rounding)", student: "0.7", expected: "\\frac{28}{\\sqrt{2009}}", outcome: .incorrect),
        Case(name: "0.3333 vs 1/3 ⇒ exactForm", student: "0.3333", expected: "\\frac{1}{3}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),
        Case(name: "1/3 vs 0.3333 with 4 decimals", student: "\\frac{1}{3}", expected: "0.3333", conditions: AnswerConditions(roundingDecimals: 4), outcome: .correct),
        Case(name: "0.33x vs x/3 ⇒ exactForm", student: "0.33x", expected: "\\frac{x}{3}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),
        Case(name: "3.14 vs π rounded", student: "3.14", expected: "\\pi", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),
        Case(name: "explicit tolerance", student: "3.1", expected: "\\pi", conditions: AnswerConditions(roundingDecimals: 2, tolerance: 0.05), outcome: .correct),
        Case(name: "exactRadicals with rounding", student: "1.41", expected: "\\sqrt{2}", conditions: AnswerConditions(roundingDecimals: 2, exactRadicals: true), outcome: .equivalentButConditionFailed, failed: ["exactRadicals"]),

        // Rationalized denominator
        Case(name: "1/√2 fails rationalizedDenominator", student: "\\frac{1}{\\sqrt{2}}", expected: "\\frac{\\sqrt{2}}{2}", conditions: AnswerConditions(rationalizedDenominator: true), outcome: .equivalentButConditionFailed, failed: ["rationalizedDenominator"]),
        Case(name: "√2/2 passes rationalizedDenominator", student: "\\frac{\\sqrt{2}}{2}", expected: "\\frac{1}{\\sqrt{2}}", conditions: AnswerConditions(rationalizedDenominator: true), outcome: .correct),
        Case(name: "3^{-1/2} fails rationalizedDenominator", student: "3^{-1/2}", expected: "\\frac{\\sqrt{3}}{3}", conditions: AnswerConditions(rationalizedDenominator: true), outcome: .equivalentButConditionFailed, failed: ["rationalizedDenominator"]),

        // Simplified
        Case(name: "2/4 fails simplified", student: "\\frac{2}{4}", expected: "\\frac{1}{2}", conditions: AnswerConditions(simplified: true), outcome: .equivalentButConditionFailed, failed: ["simplified"]),
        Case(name: "(x²−1)/(x−1) fails simplified", student: "\\frac{x^2-1}{x-1}", expected: "x+1", conditions: AnswerConditions(simplified: true), outcome: .equivalentButConditionFailed, failed: ["simplified"]),
        Case(name: "2x+3x fails simplified", student: "2x+3x", expected: "5x", conditions: AnswerConditions(simplified: true), outcome: .equivalentButConditionFailed, failed: ["simplified"]),
        Case(name: "√8 fails simplified", student: "\\sqrt{8}", expected: "2\\sqrt{2}", conditions: AnswerConditions(simplified: true), outcome: .equivalentButConditionFailed, failed: ["simplified"]),
        Case(name: "5x passes simplified", student: "5x", expected: "2x+3x", conditions: AnswerConditions(simplified: true), outcome: .correct),
        Case(name: "(3x−1)/2 passes simplified", student: "\\frac{3x-1}{2}", expected: "\\frac{3x-1}{2}", conditions: AnswerConditions(simplified: true), outcome: .correct),
        Case(name: "4√41/41 passes simplified + rationalized", student: "\\frac{4\\sqrt{41}}{41}", expected: "\\frac{28}{\\sqrt{2009}}", conditions: AnswerConditions(rationalizedDenominator: true, simplified: true), outcome: .correct),

        // Factored / expanded
        Case(name: "(x+1)^2 fails expanded", student: "(x+1)^2", expected: "x^2+2x+1", conditions: AnswerConditions(expanded: true), outcome: .equivalentButConditionFailed, failed: ["expanded"]),
        Case(name: "x^2+2x+1 passes expanded", student: "x^2+2x+1", expected: "(x+1)^2", conditions: AnswerConditions(expanded: true), outcome: .correct),
        Case(name: "28(x−1)+… fails expanded", student: "28(x-1)+35(y-2)+22", expected: "28x+35y-76", conditions: AnswerConditions(expanded: true), outcome: .equivalentButConditionFailed, failed: ["expanded"]),
        Case(name: "x^2+2x+1 fails factored", student: "x^2+2x+1", expected: "(x+1)^2", conditions: AnswerConditions(factored: true), outcome: .equivalentButConditionFailed, failed: ["factored"]),
        Case(name: "(x+1)^2 passes factored", student: "(x+1)^2", expected: "x^2+2x+1", conditions: AnswerConditions(factored: true), outcome: .correct),
        Case(name: "(x+1)(x²−1) not fully factored", student: "(x+1)(x^2-1)", expected: "x^3+x^2-x-1", conditions: AnswerConditions(factored: true), outcome: .equivalentButConditionFailed, failed: ["factored"]),
        Case(name: "x^2+1 (irreducible) passes factored", student: "x^2+1", expected: "x^2+1", conditions: AnswerConditions(factored: true), outcome: .correct),
        Case(name: "2x+2 fails factored", student: "2x+2", expected: "2(x+1)", conditions: AnswerConditions(factored: true), outcome: .equivalentButConditionFailed, failed: ["factored"]),

        // Equations
        Case(name: "y = 2x+1 ≡ 2x − y + 1 = 0", student: "y = 2x+1", expected: "2x - y + 1 = 0", outcome: .correct),
        Case(name: "implicit ≡ explicit", student: "2x - y + 1 = 0", expected: "y = 2x+1", outcome: .correct),
        Case(name: "implicit fails explicit", student: "2x - y + 1 = 0", expected: "y = 2x+1", conditions: AnswerConditions(explicit: true), outcome: .equivalentButConditionFailed, failed: ["explicit"]),
        Case(name: "explicit passes explicit", student: "y = 2x+1", expected: "2x - y + 1 = 0", conditions: AnswerConditions(explicit: true), outcome: .correct),
        Case(name: "reversed sides still explicit", student: "2x+1 = y", expected: "y=2x+1", conditions: AnswerConditions(explicit: true), outcome: .correct),
        Case(name: "scaled equation equivalent", student: "2y = 4x + 2", expected: "y = 2x+1", outcome: .correct),
        Case(name: "scaled equation not explicit", student: "2y = 4x + 2", expected: "y = 2x+1", conditions: AnswerConditions(explicit: true), outcome: .equivalentButConditionFailed, failed: ["explicit"]),
        Case(name: "implicit not allowed", student: "2x - y + 1 = 0", expected: "y = 2x+1", conditions: AnswerConditions(implicitAllowed: false), outcome: .equivalentButConditionFailed, failed: ["implicitAllowed"]),
        Case(name: "wrong equation", student: "y = 2x+2", expected: "2x - y + 1 = 0", outcome: .incorrect),
        Case(name: "bare RHS for y = …", student: "2x+1", expected: "y = 2x+1", outcome: .correct),
        Case(name: "bare RHS fails explicit", student: "2x+1", expected: "y = 2x+1", conditions: AnswerConditions(explicit: true), outcome: .equivalentButConditionFailed, failed: ["explicit"]),
        Case(name: "f(x) = … for bare expression", student: "f(x) = 2x+1", expected: "2x+1", outcome: .correct),
        Case(name: "inequality direction normalised", student: "x > 2", expected: "2 < x", outcome: .correct),
        Case(name: "inequality scaled", student: "2x > 4", expected: "x > 2", outcome: .correct),
        Case(name: "inequality flipped is wrong", student: "x < 2", expected: "x > 2", outcome: .incorrect),

        // Solution sets and collections
        Case(name: "x=2, x=−2 vs {−2, 2}", student: "x=2, x=-2", expected: "\\{-2, 2\\}", outcome: .correct),
        Case(name: "set vs equation list", student: "\\{2,-2\\}", expected: "x=-2, x=2", outcome: .correct),
        Case(name: "x = ±2", student: "x=\\pm 2", expected: "\\{-2, 2\\}", outcome: .correct),
        Case(name: "x = 2 or x = −2", student: "x = 2 \\text{ or } x = -2", expected: "\\{-2, 2\\}", outcome: .correct),
        Case(name: "comma list of values", student: "2, -2", expected: "\\{-2, 2\\}", outcome: .correct),
        Case(name: "missing solution", student: "x=2", expected: "\\{-2, 2\\}", outcome: .incorrect),
        Case(name: "wrong solution", student: "x=2, x=3", expected: "\\{-2, 2\\}", outcome: .incorrect),
        Case(name: "system solution order-insensitive", student: "y = 4, x = 3", expected: "x = 3, y = 4", outcome: .correct),
        Case(name: "system solution swapped values", student: "x = 4, y = 3", expected: "x = 3, y = 4", outcome: .incorrect),
        Case(name: "vector ⟨28/√2009, 35/√2009⟩", student: "\\langle \\frac{28}{\\sqrt{2009}}, \\frac{35}{\\sqrt{2009}} \\rangle", expected: "\\langle \\frac{4\\sqrt{41}}{41}, \\frac{5\\sqrt{41}}{41} \\rangle", outcome: .correct),
        Case(name: "vector components swapped", student: "\\langle \\frac{35}{\\sqrt{2009}}, \\frac{28}{\\sqrt{2009}} \\rangle", expected: "\\langle \\frac{4\\sqrt{41}}{41}, \\frac{5\\sqrt{41}}{41} \\rangle", outcome: .incorrect),
        Case(name: "tuple order matters", student: "(2,1)", expected: "(1,2)", outcome: .incorrect),
        Case(name: "column vector vs angle brackets", student: "\\begin{pmatrix}1\\\\2\\end{pmatrix}", expected: "\\langle 1, 2\\rangle", outcome: .correct),

        // Units
        Case(name: "3 \\text{ m} with units", student: "3 \\text{ m}", expected: "3 \\text{ m}", conditions: AnswerConditions(units: "m"), outcome: .correct),
        Case(name: "missing units", student: "3", expected: "3", conditions: AnswerConditions(units: "m"), outcome: .equivalentButConditionFailed, failed: ["units"]),
        Case(name: "wrong units", student: "3 \\text{ cm}", expected: "3", conditions: AnswerConditions(units: "m"), outcome: .equivalentButConditionFailed, failed: ["units"]),
        Case(name: "\\mathrm units", student: "3\\,\\mathrm{m}", expected: "3", conditions: AnswerConditions(units: "m"), outcome: .correct),
        Case(name: "plain suffix units", student: "3 m", expected: "3", conditions: AnswerConditions(units: "m"), outcome: .correct),

        // Chained inequalities compare every adjacent pair
        Case(name: "2<x<6 vs 2<x<5 is wrong", student: "2<x<6", expected: "2<x<5", outcome: .incorrect),
        Case(name: "-1<x<1 vs -1<x<2 is wrong", student: "-1<x<1", expected: "-1<x<2", outcome: .incorrect),
        Case(name: "0<x<1 vs 0<x is wrong", student: "0<x<1", expected: "0<x", outcome: .incorrect),
        Case(name: "4<2x<10 ≡ 2<x<5", student: "4<2x<10", expected: "2<x<5", outcome: .correct),
        Case(name: "-1≤x≤1 ≡ itself", student: "-1\\le x\\le 1", expected: "-1\\le x\\le 1", outcome: .correct),

        // Ordered point against a labelled system (x, y, z order)
        Case(name: "(3,2) vs x=2,y=3 is wrong", student: "(3,2)", expected: "x=2,y=3", outcome: .incorrect),
        Case(name: "(2,3) vs x=2,y=3", student: "(2,3)", expected: "x=2,y=3", outcome: .correct),
        Case(name: "x=3,y=2 vs (2,3) is wrong", student: "x=3,y=2", expected: "(2,3)", outcome: .incorrect),
        Case(name: "y=3,x=2 vs (2,3)", student: "y=3,x=2", expected: "(2,3)", outcome: .correct),
        Case(name: "vector vs set is not a multiset match", student: "\\langle2,1\\rangle", expected: "\\{1,2\\}", outcome: .incorrect),

        // Intervals: endpoint inclusivity
        Case(name: "[2,5] vs (2,5) is wrong", student: "[2,5]", expected: "(2,5)", outcome: .incorrect),
        Case(name: "(2,5) vs [2,5] is wrong", student: "(2,5)", expected: "[2,5]", outcome: .incorrect),
        Case(name: "\\left[2,5\\right] vs (2,5) is wrong", student: "\\left[2,5\\right]", expected: "(2,5)", outcome: .incorrect),
        Case(name: "\\left[2,5\\right] ≡ [2,5]", student: "\\left[2,5\\right]", expected: "[2,5]", outcome: .correct),
        Case(name: "[2,5) vs [2,5] is wrong", student: "[2,5)", expected: "[2,5]", outcome: .incorrect),
        Case(name: "[2,∞) vs (2,∞) is wrong", student: "[2,\\infty)", expected: "(2,\\infty)", outcome: .incorrect),
        Case(name: "[2,∞) ≡ itself", student: "[2,\\infty)", expected: "[2,\\infty)", outcome: .correct),

        // Calculator-precision decimals are not exact
        Case(name: "0.6666666667 vs 2/3 ⇒ exactForm", student: "0.6666666667", expected: "\\frac{2}{3}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),
        Case(name: "0.3333333333 vs 1/3 ⇒ exactForm", student: "0.3333333333", expected: "\\frac{1}{3}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),
        Case(name: "1.4142135624 vs √2 ⇒ exactForm", student: "1.4142135624", expected: "\\sqrt{2}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),
        Case(name: "0.6666666667 vs 2/3 rounded ⇒ correct", student: "0.6666666667", expected: "\\frac{2}{3}", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),
        Case(name: "1.5x ≡ 3x/2 exactly", student: "1.5x", expected: "\\frac{3x}{2}", outcome: .correct),
        Case(name: "x^{0.5} ≡ √x exactly", student: "x^{0.5}", expected: "\\sqrt{x}", outcome: .correct),
        Case(name: "{0.5, 1.5} ≡ {1/2, 3/2} exactly", student: "\\{0.5, 1.5\\}", expected: "\\{\\frac{1}{2}, \\frac{3}{2}\\}", outcome: .correct),
        Case(name: "y=0.33x vs y=x/3 ⇒ exactForm", student: "y=0.33x", expected: "y=\\frac{x}{3}", outcome: .equivalentButConditionFailed, failed: ["exactForm"]),

        // Spacing commands are ignored
        Case(name: "x\\,+\\,1 ≡ x+1", student: "x\\,+\\,1", expected: "x+1", outcome: .correct),
        Case(name: "x\\;+1 ≡ x+1", student: "x\\;+1", expected: "x+1", outcome: .correct),
        Case(name: "x\\quad+1 ≡ x+1", student: "x\\quad+1", expected: "x+1", outcome: .correct),
        Case(name: "x^2\\,-\\,1 ≡ x^2-1", student: "x^2\\,-\\,1", expected: "x^2-1", outcome: .correct),
        Case(name: "-x^2 vs x^2\\,-\\,1 is wrong", student: "-x^2", expected: "x^2\\,-\\,1", outcome: .incorrect),
        Case(name: "x\\,y ≡ xy", student: "x\\,y", expected: "xy", outcome: .correct),

        // Simplified: sign placement and single fractions
        Case(name: "-x/2 passes simplified", student: "-\\frac{x}{2}", expected: "-\\frac{x}{2}", conditions: AnswerConditions(simplified: true), outcome: .correct),
        Case(name: "-π/6 passes simplified", student: "-\\frac{\\pi}{6}", expected: "-\\frac{\\pi}{6}", conditions: AnswerConditions(simplified: true), outcome: .correct),
        Case(name: "-2x/(x²+1)² passes simplified", student: "-\\frac{2x}{(x^2+1)^2}", expected: "-\\frac{2x}{(x^2+1)^2}", conditions: AnswerConditions(simplified: true), outcome: .correct),
        Case(name: "(x²+1)/x passes simplified", student: "\\frac{x^2+1}{x}", expected: "\\frac{x^2+1}{x}", conditions: AnswerConditions(simplified: true), outcome: .correct),
        Case(name: "(x²+x)/x² fails simplified", student: "\\frac{x^2+x}{x^2}", expected: "\\frac{x+1}{x}", conditions: AnswerConditions(simplified: true), outcome: .equivalentButConditionFailed, failed: ["simplified"]),

        // Expanded: constants stay symbolic
        Case(name: "e^x passes expanded", student: "e^{x}", expected: "e^{x}", conditions: AnswerConditions(expanded: true), outcome: .correct),
        Case(name: "2e^x passes expanded", student: "2e^{x}", expected: "2e^{x}", conditions: AnswerConditions(expanded: true), outcome: .correct),
        Case(name: "πr² passes expanded", student: "\\pi r^2", expected: "\\pi r^2", conditions: AnswerConditions(expanded: true), outcome: .correct),
        Case(name: "xe^x+e^x passes expanded", student: "xe^x+e^x", expected: "(x+1)e^x", conditions: AnswerConditions(expanded: true), outcome: .correct),
        Case(name: "(x+1)e^x fails expanded", student: "(x+1)e^x", expected: "xe^x+e^x", conditions: AnswerConditions(expanded: true), outcome: .equivalentButConditionFailed, failed: ["expanded"]),
        Case(name: "-x/2 passes expanded", student: "-\\frac{x}{2}", expected: "-\\frac{x}{2}", conditions: AnswerConditions(expanded: true), outcome: .correct),

        // Explicit: derivative labels
        Case(name: "dy/dx = 2x passes explicit", student: "\\frac{dy}{dx}=2x", expected: "\\frac{dy}{dx}=2x", conditions: AnswerConditions(explicit: true), outcome: .correct),
        Case(name: "y' = 2x passes explicit", student: "y'=2x", expected: "y'=2x", conditions: AnswerConditions(explicit: true), outcome: .correct),
        Case(name: "y' = 2x passes implicitAllowed:false", student: "y'=2x", expected: "y'=2x", conditions: AnswerConditions(implicitAllowed: false), outcome: .correct),
        Case(name: "dy/dx = -x/y passes explicit", student: "\\frac{dy}{dx}=-\\frac{x}{y}", expected: "\\frac{dy}{dx}=-\\frac{x}{y}", conditions: AnswerConditions(explicit: true), outcome: .correct),

        // Single solution against a one-element set
        Case(name: "x=2 vs {2}", student: "x=2", expected: "\\{2\\}", outcome: .correct),
        Case(name: "2 vs {2}", student: "2", expected: "\\{2\\}", outcome: .correct),
        Case(name: "{2} vs x=2", student: "\\{2\\}", expected: "x=2", outcome: .correct),
        Case(name: "x=1/2 vs {0.5}", student: "x=\\frac{1}{2}", expected: "\\{0.5\\}", outcome: .correct),
        Case(name: "x=3 vs {2} is wrong", student: "x=3", expected: "\\{2\\}", outcome: .incorrect),
        Case(name: "2 vs {2,3} is wrong", student: "2", expected: "\\{2,3\\}", outcome: .incorrect),

        // Rounded coefficients with variables
        Case(name: "0.33x vs x/3 rounded", student: "0.33x", expected: "\\frac{x}{3}", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),
        Case(name: "3.14r² vs πr² rounded", student: "3.14r^2", expected: "\\pi r^2", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),
        Case(name: "0.3x vs x/3 rounded is wrong", student: "0.3x", expected: "\\frac{x}{3}", conditions: AnswerConditions(roundingDecimals: 2), outcome: .incorrect),
        Case(name: "2.7x vs ex rounded is wrong", student: "2.7x", expected: "ex", conditions: AnswerConditions(roundingDecimals: 2), outcome: .incorrect),
        Case(name: "1.41x+3.14 vs √2x+π rounded", student: "1.41x+3.14", expected: "\\sqrt{2}x+\\pi", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),
        Case(name: "0.33/x vs 1/(3x) rounded", student: "\\frac{0.33}{x}", expected: "\\frac{1}{3x}", conditions: AnswerConditions(roundingDecimals: 2), outcome: .correct),

        // Comma lists of solutions are order-insensitive
        Case(name: "x=2,-2 vs x=-2,2", student: "x=2,-2", expected: "x=-2,2", outcome: .correct),
        Case(name: "θ=5π/6,π/6 vs θ=π/6,5π/6", student: "\\theta=\\frac{5\\pi}{6},\\frac{\\pi}{6}", expected: "\\theta=\\frac{\\pi}{6},\\frac{5\\pi}{6}", outcome: .correct),
        Case(name: "x=2,-2 vs x=2,x=-2", student: "x=2,-2", expected: "x=2,x=-2", outcome: .correct),
        Case(name: "bare 2,-2 vs -2,2", student: "2,-2", expected: "-2,2", outcome: .correct),
        Case(name: "x=2,3 vs x=2,-2 is wrong", student: "x=2,3", expected: "x=2,-2", outcome: .incorrect),
        Case(name: "(2,-2) vs (-2,2) stays ordered", student: "(2,-2)", expected: "(-2,2)", outcome: .incorrect),

        // Unions of intervals
        Case(name: "union order-insensitive", student: "(2,\\infty)\\cup(-\\infty,2)", expected: "(-\\infty,2)\\cup(2,\\infty)", outcome: .correct),
        Case(name: "union with closed ends order-insensitive", student: "[2,\\infty)\\cup(-\\infty,0]", expected: "(-\\infty,0]\\cup[2,\\infty)", outcome: .correct),
        Case(name: "union with wrong inclusivity", student: "(2,\\infty)\\cup(-\\infty,0]", expected: "(-\\infty,0]\\cup[2,\\infty)", outcome: .incorrect),
        Case(name: "three-piece union reordered", student: "(-\\infty,2)\\cup(2,\\infty)\\cup(3,4)", expected: "(3,4)\\cup(-\\infty,2)\\cup(2,\\infty)", outcome: .correct),
        Case(name: "union with wrong endpoint", student: "(-\\infty,2)\\cup(2,\\infty)", expected: "(-\\infty,3)\\cup(3,\\infty)", outcome: .incorrect),
        Case(name: "missing union piece", student: "(-\\infty,2)", expected: "(-\\infty,2)\\cup(2,\\infty)", outcome: .incorrect),

        // Unparseable
        Case(name: "unclosed fraction", student: "\\frac{", expected: "x", outcome: .unparseable),
        Case(name: "empty answer", student: "", expected: "x", outcome: .unparseable),
        Case(name: "dangling equals", student: "x=", expected: "x", outcome: .unparseable),
        Case(name: "unparseable expected ⇒ needsTutor", student: "x", expected: "\\frac{", outcome: .needsTutor),
    ]

    func testGradingMatrix() async {
        XCTAssertGreaterThanOrEqual(Self.cases.count, 40)
        for c in Self.cases {
            let verdict = await Self.engine.grade(
                student: c.student,
                expected: AnswerSpec(latex: c.expected, alternatives: c.alternatives),
                conditions: c.conditions,
                kind: .math
            )
            XCTAssertEqual(verdict.outcome, c.outcome, "\(c.name): \(verdict.message) \(verdict.failedConditions)")
            if !c.failed.isEmpty {
                XCTAssertEqual(verdict.failedConditions, c.failed, c.name)
            }
            XCTAssertFalse(verdict.message.isEmpty, c.name)
        }
    }

    // MARK: - Verdict details

    func testMessagesNeverRevealTheExpectedAnswer() async {
        let verdict = await Self.engine.grade(
            student: "0.6247",
            expected: AnswerSpec(latex: "\\frac{28}{\\sqrt{2009}}"),
            conditions: .none,
            kind: .math
        )
        XCTAssertEqual(verdict.outcome, .equivalentButConditionFailed)
        XCTAssertFalse(verdict.message.contains("2009"))
        XCTAssertFalse(verdict.message.contains("41"))
        XCTAssertEqual(verdict.canonicalExpected, "\\frac{4\\sqrt{41}}{41}")
    }

    func testCanonicalFormsAreFilled() async {
        let verdict = await Self.engine.grade(
            student: "\\frac{2}{4}x",
            expected: AnswerSpec(latex: "\\frac{1}{2}x"),
            conditions: .none,
            kind: .numeric
        )
        XCTAssertEqual(verdict.outcome, .correct)
        XCTAssertEqual(verdict.canonicalStudent, "\\frac{x}{2}")
        XCTAssertEqual(verdict.canonicalExpected, "\\frac{x}{2}")
        XCTAssertTrue(verdict.isCorrect)
    }

    func testChainedInequalityDisplayKeepsBothBounds() async {
        let verdict = await Self.engine.grade(
            student: "2<x<6",
            expected: AnswerSpec(latex: "2<x<5"),
            conditions: .none,
            kind: .math
        )
        XCTAssertEqual(verdict.outcome, .incorrect)
        XCTAssertEqual(verdict.canonicalStudent, "2\\lt x\\lt6")
        XCTAssertEqual(verdict.canonicalExpected, "2\\lt x\\lt5")
    }

    func testMultipleFailedConditionsAreAllReported() async {
        let verdict = await Self.engine.grade(
            student: "\\frac{2}{2\\sqrt{2}}",
            expected: AnswerSpec(latex: "\\frac{\\sqrt{2}}{2}"),
            conditions: AnswerConditions(rationalizedDenominator: true, simplified: true),
            kind: .math
        )
        XCTAssertEqual(verdict.outcome, .equivalentButConditionFailed)
        XCTAssertTrue(verdict.failedConditions.contains("rationalizedDenominator"), "\(verdict.failedConditions)")
        XCTAssertTrue(verdict.failedConditions.contains("simplified"), "\(verdict.failedConditions)")
    }

    func testMissingExpectedAnswerNeedsTutor() async {
        let verdict = await Self.engine.grade(student: "x", expected: AnswerSpec(), conditions: .none, kind: .math)
        XCTAssertEqual(verdict.outcome, .needsTutor)
    }

    func testFreeResponseAlwaysNeedsTutor() async {
        let verdict = await Self.engine.grade(
            student: "Because the derivative is zero there.",
            expected: AnswerSpec(rubric: "Mentions the derivative"),
            conditions: .none,
            kind: .freeResponse
        )
        XCTAssertEqual(verdict.outcome, .needsTutor)
    }

    // MARK: - Text and choice grading

    func testTextGradingIsCaseAndWhitespaceInsensitive() async {
        let expected = AnswerSpec(alternatives: ["mitochondrion"], text: "Mitochondria")
        let correct = await Self.engine.grade(student: "  mitochondria. ", expected: expected, conditions: .none, kind: .text)
        XCTAssertEqual(correct.outcome, .correct)
        let alternative = await Self.engine.grade(student: "MITOCHONDRION", expected: expected, conditions: .none, kind: .text)
        XCTAssertEqual(alternative.outcome, .correct)
        let wrong = await Self.engine.grade(student: "ribosome", expected: expected, conditions: .none, kind: .text)
        XCTAssertEqual(wrong.outcome, .incorrect)
        let empty = await Self.engine.grade(student: "   ", expected: expected, conditions: .none, kind: .text)
        XCTAssertEqual(empty.outcome, .unparseable)
    }

    func testChoiceGradingMatchesOptionText() async {
        let expected = AnswerSpec(text: "$x = 2$")
        let verdict = await Self.engine.grade(student: "x = 2", expected: expected, conditions: .none, kind: .choice)
        XCTAssertEqual(verdict.outcome, .correct)
    }

    func testNormalizeText() {
        XCTAssertEqual(GradingRules.normalizeText("  Hello   World! "), "hello world")
        XCTAssertEqual(GradingRules.normalizeText("$x^2$"), "x^2")
        XCTAssertEqual(GradingRules.normalizeText(""), "")
    }

    // MARK: - Calculator

    func testEvaluateReturnsAtMostTenSignificantDigits() async throws {
        let twoThirds = try await Self.engine.evaluate("\\frac{2}{3}")
        XCTAssertEqual(twoThirds, "0.6666666667")
        let pi = try await Self.engine.evaluate("\\pi")
        XCTAssertEqual(pi, "3.141592654")
        let integer = try await Self.engine.evaluate("2+3")
        XCTAssertEqual(integer, "5")
        let big = try await Self.engine.evaluate("10^{30}")
        XCTAssertEqual(big, "1\\times10^{30}")
        let complex = try await Self.engine.evaluate("\\sqrt{-4}")
        XCTAssertEqual(complex, "2i")
        let symbolic = try await Self.engine.evaluate("x+1")
        XCTAssertEqual(symbolic, "x+1")
    }

    func testEvaluateRejectsInvalidLatex() async {
        do {
            _ = try await Self.engine.evaluate("\\frac{")
            XCTFail("expected a parse error")
        } catch let error as ThubanError {
            guard case .parse = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSimplify() async throws {
        let simplified = try await Self.engine.simplify("\\frac{x^2-1}{x-1}")
        XCTAssertEqual(simplified, "x+1")
        let trig = try await Self.engine.simplify("\\sin^2 x + \\cos^2 x")
        XCTAssertEqual(trig, "1")
    }

    // MARK: - Performance

    func testGradingIsFastAfterWarmUp() async throws {
        try await Self.engine.warmUp()
        let loaded = await Self.engine.isLoaded
        XCTAssertTrue(loaded)
        let started = Date()
        let iterations = 10
        for _ in 0..<iterations {
            _ = await Self.engine.grade(
                student: "28(x-1)+35(y-2)+22",
                expected: AnswerSpec(latex: "28x+35y-76"),
                conditions: AnswerConditions(simplified: true),
                kind: .math
            )
        }
        let perCall = Date().timeIntervalSince(started) / Double(iterations)
        XCTAssertLessThan(perCall, 0.25, "grading took \(perCall * 1000) ms per call")
    }
}
