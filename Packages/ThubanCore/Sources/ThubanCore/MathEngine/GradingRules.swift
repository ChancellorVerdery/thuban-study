import Foundation

/// The grading policy shared by the Swift and JavaScript halves of the engine. Math and numeric parts are graded
/// by the helper script (see `MathEngineScript`); text and choice parts are graded here; free-response parts are
/// always handed to the tutor.
///
/// Algorithm for math parts (implemented in the helper script):
/// 1. Parse both sides; an unparseable student answer is `.unparseable`, an unparseable expected answer `.needsTutor`.
/// 2. Equations are compared by moving everything to one side and testing that the differences agree up to a
///    nonzero constant factor (symbolically, then by sampling `equationSamplePoints` random points).
/// 3. Expressions are compared with `isEqual`, then `simplify(A − B) == 0`, then numeric sampling at
///    `samplePoints` random points in `[-sampleRange, sampleRange]` with relative tolerance `relativeTolerance`
///    (non-finite points skipped, at least `minimumAgreeingPoints` needed). Vectors and tuples are compared
///    componentwise; solution sets are compared as order-insensitive multisets.
/// 4. Exactness: with `roundingDecimals == nil`, a decimal literal that is only approximately equal fails
///    `exactForm`; with rounding allowed, agreement within `0.5·10^−decimals` (or `tolerance`) is accepted.
/// 5. Conditions are checked only after equivalence: rationalizedDenominator, simplified, factored, expanded,
///    explicit / implicitAllowed, units, exactRadicals.
/// 6. Engineering quantities (conditions with `significantFigures` or `relativeTolerance`, or vectors written with
///    unit vectors i, j, k) are graded numerically first: a trailing unit in any spelling ("8.1kN", "\\text{lbf/in}^2",
///    "\\frac{lbf}{in^2}", "19.9°") is converted to the part's unit (a bare number is taken to be in it; a unit of
///    another kind is incorrect), i-j-k sums become component tuples, and each component is accepted within
///    max(absolute tolerance, relativeTolerance·|expected|, half a unit in the last significant figure). Answers that
///    are not plain numbers or vectors fall through to the general grader.
/// 7. Messages never reveal the expected answer.
public enum GradingRules {
    /// Random points sampled when comparing expressions numerically.
    public static let samplePoints = 12
    /// Random points sampled when comparing implicit equations.
    public static let equationSamplePoints = 8
    /// Valid, agreeing sample points required for a numeric equivalence verdict.
    public static let minimumAgreeingPoints = 6
    /// Relative tolerance for numeric equivalence.
    public static let relativeTolerance = 1e-9
    /// Half-width of the sampling interval for free variables.
    public static let sampleRange = 3.0

    /// Verdict for parts that the engine never grades (free response).
    public static let tutorVerdict = Verdict(
        outcome: .needsTutor,
        message: "This part is reviewed by the tutor rather than checked automatically."
    )

    /// Verdict used when the engine itself fails; the student is pointed at the tutor instead of being marked wrong.
    public static let engineFailureVerdict = Verdict(
        outcome: .needsTutor,
        message: "This part couldn't be checked automatically right now. Ask the tutor to review it."
    )

    /// Verdict for a part whose expected answer is missing from the bank.
    public static let missingExpectedVerdict = Verdict(
        outcome: .needsTutor,
        message: "This part has no stored answer to check against. Ask the tutor to review it."
    )

    /// Grades `.text` and `.choice` parts: case- and whitespace-insensitive comparison against the expected text
    /// and every alternative.
    public static func gradeText(student: String, expected: AnswerSpec) -> Verdict {
        var accepted = expected.alternatives
        if let text = expected.text { accepted.insert(text, at: 0) }
        if let latex = expected.latex { accepted.append(latex) }
        let normalizedAccepted = accepted.map(normalizeText).filter { !$0.isEmpty }
        guard !normalizedAccepted.isEmpty else { return missingExpectedVerdict }
        let normalizedStudent = normalizeText(student)
        guard !normalizedStudent.isEmpty else {
            return Verdict(outcome: .unparseable, message: "Enter an answer for this part.", canonicalStudent: nil, canonicalExpected: nil)
        }
        if normalizedAccepted.contains(normalizedStudent) {
            return Verdict(outcome: .correct, message: "Correct.", canonicalStudent: normalizedStudent, canonicalExpected: normalizedAccepted[0])
        }
        return Verdict(outcome: .incorrect, message: "Not quite. Check your answer and try again.", canonicalStudent: normalizedStudent, canonicalExpected: normalizedAccepted[0])
    }

    /// Lowercases, trims, collapses whitespace, and strips surrounding `$` and trailing punctuation.
    public static func normalizeText(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("$") { value.removeFirst() }
        while value.hasSuffix("$") { value.removeLast() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, ".!,;".contains(last) { value.removeLast() }
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Request shape handed to the helper script's `grade`.
    struct GradeRequest: Encodable {
        var student: String
        var expected: String?
        var alternatives: [String]
        var conditions: AnswerConditions
    }
}
