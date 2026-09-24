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

    /// Grades `.text` and `.choice` parts: case-, spacing- and punctuation-insensitive comparison against the expected
    /// text, every alternative, and the forms the key itself offers: "size (energy level / principal energy shell)"
    /// accepts "size", "energy level" and "principal energy shell". Lists ("0, 1, 2, 3") match item by item in any
    /// order and with any spacing. A text answer that still does not match is `.incorrect` here; the study session
    /// then asks the tutor model whether it means the same thing (`TextAnswerJudge`).
    public static func gradeText(student: String, expected: AnswerSpec, loose: Bool = true) -> Verdict {
        var keys = expected.alternatives
        if let text = expected.text { keys.insert(text, at: 0) }
        if let latex = expected.latex { keys.append(latex) }
        let normalizedKeys = keys.map(normalizeText).filter { !$0.isEmpty }
        guard !normalizedKeys.isEmpty else { return missingExpectedVerdict }
        let normalizedStudent = normalizeText(student)
        guard !normalizedStudent.isEmpty else {
            return Verdict(outcome: .unparseable, message: "Enter an answer for this part.", canonicalStudent: nil, canonicalExpected: nil)
        }
        let accepted = loose ? keys.flatMap(acceptedForms) : normalizedKeys
        if accepted.contains(where: { textMatches(normalizedStudent, $0) }) {
            return Verdict(outcome: .correct, message: "Correct.", canonicalStudent: normalizedStudent, canonicalExpected: normalizedKeys[0])
        }
        return Verdict(outcome: .incorrect, message: "Not quite. Check your answer and try again.", canonicalStudent: normalizedStudent, canonicalExpected: normalizedKeys[0])
    }

    /// The normalized forms one key accepts: the whole key, the key without its parentheticals, and each alternative
    /// offered in parentheses or separated by " / " or ";" (and " or " within parentheses) ("size (energy level / principal energy shell)").
    static func acceptedForms(_ key: String) -> [String] {
        var forms: [String] = [key]
        var outside = ""
        var inside: [String] = []
        var depth = 0
        var current = ""
        for character in key {
            if character == "(" {
                if depth == 0 { current = "" } else { current.append(character) }
                depth += 1
            } else if character == ")", depth > 0 {
                depth -= 1
                if depth == 0 { inside.append(current); outside.append(" ") } else { current.append(character) }
            } else if depth > 0 {
                current.append(character)
            } else {
                outside.append(character)
            }
        }
        if !inside.isEmpty {
            forms.append(outside)
            forms.append(contentsOf: inside)
        }
        var split: [String] = []
        for form in forms {
            // " or " separates alternatives only inside parentheses: "increases or decreases" is one answer.
            let pieces = form.components(separatedBy: " / ")
                .flatMap { inside.contains(form) ? $0.components(separatedBy: " or ") : [$0] }
                .flatMap { $0.components(separatedBy: ";") }
            if pieces.count > 1 { split.append(contentsOf: pieces) }
        }
        forms.append(contentsOf: split)
        var seen = Set<String>()
        return forms.map(normalizeText).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Equal after normalization, ignoring a leading article, or equal as lists (comma-separated items in any order,
    /// any spacing).
    static func textMatches(_ student: String, _ key: String) -> Bool {
        if student == key { return true }
        if dropArticle(student) == dropArticle(key) { return true }
        let studentItems = listItems(student)
        let keyItems = listItems(key)
        if keyItems.count > 1, studentItems.count == keyItems.count {
            return studentItems.map(dropArticle).sorted() == keyItems.map(dropArticle).sorted()
        }
        return false
    }

    private static func dropArticle(_ text: String) -> String {
        for article in ["the ", "a ", "an "] where text.hasPrefix(article) {
            return String(text.dropFirst(article.count))
        }
        return text
    }

    /// "0,1,2,3", "0, 1, 2 and 3", "{0, 1, 2, 3}" → ["0", "1", "2", "3"].
    static func listItems(_ text: String) -> [String] {
        var value = text
        if let first = value.first, let last = value.last, "{[(".contains(first), "}])".contains(last) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.replacingOccurrences(of: ", and ", with: ",").replacingOccurrences(of: " and ", with: ",")
        return value.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { normalizeText(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Lowercases, trims, collapses whitespace, and strips surrounding `$`, `\text{…}` and trailing punctuation.
    public static func normalizeText(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("$") { value.removeFirst() }
        while value.hasSuffix("$") { value.removeLast() }
        value = value.replacingOccurrences(of: #"\\(?:text|mathrm)\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
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
