import XCTest
@testable import ThubanCore

/// Engineering homework answers (statics, thermodynamics): units converted, significant figures / relative
/// tolerance, vectors in i-j-k form.
final class EngineeringGradingTests: XCTestCase {
    static let engine = MathEngine()

    struct Case {
        var name: String
        var student: String
        var expected: String
        var conditions: AnswerConditions
        var alternatives: [String] = []
        var outcome: Verdict.Outcome
    }

    /// Engineering defaults the import agent sets: 3 significant figures, within 1 %.
    static func eng(_ units: String? = nil) -> AnswerConditions {
        AnswerConditions(units: units, significantFigures: 3, relativeTolerance: 0.01)
    }

    static let cases: [Case] = [
        // Unit conversion and bare numbers
        Case(name: "8.1 kN for 8100 N", student: "8.1\\,\\mathrm{kN}", expected: "8100", conditions: eng("N"), outcome: .correct),
        Case(name: "8.1kN typed", student: "8.1kN", expected: "8100", conditions: eng("N"), outcome: .correct),
        Case(name: "8.10 kN text", student: "8.10\\text{ kN}", expected: "8100", conditions: eng("N"), outcome: .correct),
        Case(name: "bare number in the stated unit", student: "8100", expected: "8100", conditions: eng("N"), outcome: .correct),
        Case(name: "8.12 kN within 1 %", student: "8.12\\text{ kN}", expected: "8100", conditions: eng("N"), outcome: .correct),
        Case(name: "8.3 kN outside 1 %", student: "8.3\\text{ kN}", expected: "8100", conditions: eng("N"), outcome: .incorrect),
        Case(name: "kg for a force", student: "8100\\text{ kg}", expected: "8100", conditions: eng("N"), outcome: .incorrect),
        Case(name: "lb is a force against N", student: "1821\\text{ lb}", expected: "8100", conditions: eng("N"), outcome: .correct),
        Case(name: "lb is a mass against kg", student: "3000\\text{ lb}", expected: "1361", conditions: eng("kg"), outcome: .correct),
        Case(name: "slugs of a 3000-lb car", student: "93.2", expected: "93.2", conditions: eng("slug"), outcome: .correct),
        Case(name: "3000-lb car in kg", student: "1361\\,\\mathrm{kg}", expected: "1361", conditions: eng("kg"), outcome: .correct),
        Case(name: "slug to kg", student: "93.2\\text{ slugs}", expected: "1361", conditions: eng("kg"), outcome: .correct),
        Case(name: "650 J in Btu", student: "0.616", expected: "0.616", conditions: eng("Btu"), outcome: .correct),
        Case(name: "650 J written in J", student: "650\\text{ J}", expected: "0.616", conditions: eng("Btu"), outcome: .correct),
        Case(name: "304 kPa in lbf/in²", student: "44.1\\text{ lbf/in}^2", expected: "44.1", conditions: eng("lbf/in.^2"), outcome: .correct),
        Case(name: "44.1 psi", student: "44.1\\text{ psi}", expected: "44.1", conditions: eng("lbf/in.^2"), outcome: .correct),
        Case(name: "304 kPa typed as fraction", student: "44.1\\frac{lbf}{in^2}", expected: "44.1", conditions: eng("lbf/in.^2"), outcome: .correct),
        Case(name: "304 kPa itself", student: "304\\,\\text{kPa}", expected: "44.1", conditions: eng("lbf/in.^2"), outcome: .correct),
        Case(name: "0.135 kW in ft·lbf/s", student: "99.6", expected: "99.6", conditions: eng("ft·lbf/s"), outcome: .correct),
        Case(name: "0.135 kW itself", student: "0.135\\text{ kW}", expected: "99.6", conditions: eng("ft\\cdot lbf/s"), outcome: .correct),
        Case(name: "55 m³/h in ft³/s", student: "0.540\\,\\mathrm{ft^3/s}", expected: "0.540", conditions: eng("ft^3/s"), outcome: .correct),
        Case(name: "55 m³/h itself", student: "55\\,\\mathrm{m^{3}/h}", expected: "0.540", conditions: eng("ft^3/s"), outcome: .correct),
        Case(name: "50 km/h in ft/s", student: "45.6", expected: "45.6", conditions: eng("ft/s"), outcome: .correct),
        Case(name: "50 km/h itself", student: "50\\text{ km/h}", expected: "45.6", conditions: eng("ft/s"), outcome: .correct),
        Case(name: "378 g/s in lb/min", student: "50.0\\text{ lb/min}", expected: "50.0", conditions: eng("lb/min"), outcome: .correct),
        Case(name: "8896 N in tons", student: "1.00\\text{ ton}", expected: "1.00", conditions: eng("ton"), outcome: .correct),
        Case(name: "1 L in in³", student: "61.0\\text{ in.}^3", expected: "61.0", conditions: eng("in.^3"), outcome: .correct),
        Case(name: "500 kips in MN", student: "2.22\\text{ MN}", expected: "2.22", conditions: eng("MN"), outcome: .correct),
        Case(name: "moment 51.9 N·m", student: "51.9\\text{ N}\\cdot\\text{m}", expected: "51.9", conditions: eng("N·m"), outcome: .correct),
        Case(name: "moment typed N\\cdot m", student: "51.9N\\cdot m", expected: "51.9", conditions: eng("N\\cdot m"), outcome: .correct),
        Case(name: "moment in kN·m", student: "0.0519\\text{ kN}\\cdot\\text{m}", expected: "51.9", conditions: eng("N·m"), outcome: .correct),
        Case(name: "heat flux W/m²·K", student: "10", expected: "10", conditions: eng("W/m^2·K"), outcome: .correct),
        Case(name: "mmHg to kPa", student: "760\\text{ mmHg}", expected: "101.3", conditions: eng("kPa"), outcome: .correct),

        // Angles
        Case(name: "19.9°", student: "19.9^{\\circ}", expected: "19.9", conditions: eng("°"), outcome: .correct),
        Case(name: "19.9° typed", student: "19.9°", expected: "19.9", conditions: eng("°"), outcome: .correct),
        Case(name: "19.9 bare", student: "19.9", expected: "19.9", conditions: eng("°"), outcome: .correct),
        Case(name: "0.347 rad", student: "0.347\\text{ rad}", expected: "19.9", conditions: eng("°"), outcome: .correct),
        Case(name: "resultant 83.2 N", student: "83.2\\text{ N}", expected: "83.2", conditions: eng("N"), outcome: .correct),

        // Temperatures (absolute)
        Case(name: "37.0 °C for 98.6 °F", student: "37.0^{\\circ}\\text{C}", expected: "98.6", conditions: eng("°F"), outcome: .correct),
        Case(name: "310.2 K for 37 °C", student: "310.2\\text{ K}", expected: "37.0", conditions: eng("°C"), outcome: .correct),
        Case(name: "wrong temperature", student: "40^{\\circ}\\text{C}", expected: "98.6", conditions: eng("°F"), outcome: .incorrect),

        // Vectors
        Case(name: "i-j-k bold", student: "-150\\mathbf{i}+200\\mathbf{j}+180\\mathbf{k}", expected: "\\left(-150,\\,200,\\,180\\right)", conditions: eng("lb"), outcome: .correct),
        Case(name: "i-j-k bare", student: "-150i+200j+180k", expected: "\\left(-150,\\,200,\\,180\\right)", conditions: eng("lb"), outcome: .correct),
        Case(name: "tuple against i-j-k", student: "(-150, 200, 180)", expected: "-150\\mathbf{i}+200\\mathbf{j}+180\\mathbf{k}", conditions: eng("lb"), outcome: .correct),
        Case(name: "hats", student: "-150\\hat{i}+200\\hat{j}+180\\hat{k}", expected: "\\left(-150,200,180\\right)", conditions: eng("lb"), outcome: .correct),
        Case(name: "hat imath", student: "-150\\hat\\imath+200\\hat\\jmath+180\\hat{k}", expected: "\\left(-150,200,180\\right)", conditions: eng("lb"), outcome: .correct),
        Case(name: "vector with trailing \\text unit", student: "(-150\\mathbf{i}+200\\mathbf{j}+180\\mathbf{k})\\text{ lb}", expected: "(-150,200,180)", conditions: eng("lb"), outcome: .correct),
        Case(name: "vector with typed unit", student: "-150i+200j+180k lb", expected: "(-150,200,180)", conditions: eng("lb"), outcome: .correct),
        Case(name: "vector in kN for N key", student: "(-0.150i+0.200j+0.180k)\\text{ kN}", expected: "(-150,200,180)", conditions: eng("N"), outcome: .correct),
        Case(name: "vector rounded", student: "-149.8i+200.3j+180k", expected: "(-150,200,180)", conditions: eng("lb"), outcome: .correct),
        Case(name: "vector wrong component", student: "-150i+200j+160k", expected: "(-150,200,180)", conditions: eng("lb"), outcome: .incorrect),
        Case(name: "vector wrong sign", student: "150i+200j+180k", expected: "(-150,200,180)", conditions: eng("lb"), outcome: .incorrect),
        Case(name: "2-D vector", student: "78.3\\mathbf{i}+28.3\\mathbf{j}", expected: "(78.3, 28.3)", conditions: eng("N"), outcome: .correct),
        Case(name: "2-D against 3-D with zero k", student: "3i+4j", expected: "3\\mathbf{i}+4\\mathbf{j}+0\\mathbf{k}", conditions: eng(), outcome: .correct),
        Case(name: "missing component", student: "(3, 4)", expected: "(3, 4, 5)", conditions: eng(), outcome: .incorrect),
        Case(name: "unit vectors without engineering conditions", student: "3\\mathbf{i}-2\\mathbf{j}", expected: "(3,-2)", conditions: .none, outcome: .correct),
        Case(name: "unit-vector key, tuple answer, no conditions", student: "(3,-2)", expected: "3\\mathbf{i}-2\\mathbf{j}", conditions: .none, outcome: .correct),
        Case(name: "zero component, rounding", student: "0.001i+5j", expected: "(0, 5)", conditions: eng(), outcome: .correct),

        // More spellings
        Case(name: "unit in the expected answer", student: "8.1\\text{ kN}", expected: "8100\\,\\text{N}", conditions: eng(), outcome: .correct),
        Case(name: "mathrm kN·m", student: "0.0519\\,\\mathrm{kN\\cdot m}", expected: "51.9", conditions: eng("N·m"), outcome: .correct),
        Case(name: "lb·ft moment", student: "38.3\\text{ lb}\\cdot\\text{ft}", expected: "38.3", conditions: eng("lb·ft"), outcome: .correct),
        Case(name: "lb·ft in N·m", student: "51.9\\text{ N}\\cdot\\text{m}", expected: "38.3", conditions: eng("lb·ft"), outcome: .correct),
        Case(name: "deg spelled", student: "36.9\\text{ deg}", expected: "36.9", conditions: eng("°"), outcome: .correct),
        Case(name: "kips", student: "13\\text{ kips}", expected: "57.8", conditions: eng("kN"), outcome: .correct),
        Case(name: "vector in wrong kind of unit", student: "(-150i+200j+180k)\\text{ kg}", expected: "(-150,200,180)", conditions: eng("N"), outcome: .incorrect),
        Case(name: "variable x is not a unit", student: "5x", expected: "5x", conditions: eng(), outcome: .correct),

        // Symbolic answers still go to the general grader
        Case(name: "symbolic with sig figs", student: "F_1\\cos(70)", expected: "F_1\\cos(70)", conditions: eng(), outcome: .correct),
        Case(name: "expression in m", student: "2x", expected: "2x", conditions: eng("m"), outcome: .correct),
    ]

    func testEngineeringCases() async {
        var failures: [String] = []
        for item in Self.cases {
            let verdict = await Self.engine.grade(
                student: item.student,
                expected: AnswerSpec(latex: item.expected, alternatives: item.alternatives),
                conditions: item.conditions,
                kind: .numeric
            )
            if verdict.outcome != item.outcome {
                failures.append("\(item.name): got \(verdict.outcome.rawValue) (\(verdict.message)) student \(verdict.canonicalStudent ?? "-") expected \(verdict.canonicalExpected ?? "-")")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }

    func testImaginaryUnitUnchangedWithoutVectors() async {
        let verdict = await Self.engine.grade(student: "3+4i", expected: AnswerSpec(latex: "3+4i"), conditions: .none, kind: .math)
        XCTAssertEqual(verdict.outcome, .correct)
        let wrong = await Self.engine.grade(student: "3-4i", expected: AnswerSpec(latex: "3+4i"), conditions: .none, kind: .math)
        XCTAssertEqual(wrong.outcome, .incorrect)
        let squared = await Self.engine.grade(student: "-1", expected: AnswerSpec(latex: "i^2"), conditions: .none, kind: .math)
        XCTAssertEqual(squared.outcome, .correct)
    }

    func testUnitsAloneAreAPhysicalQuantity() async {
        // A part that only names its unit (no tolerance): bare numbers, typed units and conversions all work.
        let units = AnswerConditions(units: "mg")
        for student in ["168.1", "168.1mg", "168.1\\text{ mg}", "0.1681\\text{ g}", "168"] {
            let verdict = await Self.engine.grade(student: student, expected: AnswerSpec(latex: "168.1"), conditions: units, kind: .numeric)
            XCTAssertEqual(verdict.outcome, .correct, student)
        }
        let wrong = await Self.engine.grade(student: "175", expected: AnswerSpec(latex: "168.1"), conditions: units, kind: .numeric)
        XCTAssertEqual(wrong.outcome, .incorrect)
        let dimension = await Self.engine.grade(student: "168.1\\text{ mL}", expected: AnswerSpec(latex: "168.1"), conditions: units, kind: .numeric)
        XCTAssertNotEqual(dimension.outcome, .correct)
    }

    func testConditionSummary() {
        let conditions = AnswerConditions(units: "kN", significantFigures: 3, relativeTolerance: 0.01)
        XCTAssertEqual(conditions.summary, "3 significant figures · Within 1 %")
        let decoded = try? JSONDecoder().decode(AnswerConditions.self, from: Data(#"{"units":"kN","significantFigures":3,"relativeTolerance":0.01}"#.utf8))
        XCTAssertEqual(decoded, conditions)
    }
}
