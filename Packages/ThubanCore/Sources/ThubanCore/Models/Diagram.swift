import Foundation

// MARK: - Process diagrams

/// A "sketch it on p–V coordinates" answer: numbered states placed on a two-axis grid and joined by processes.
///
/// Axes are numeric (states sit at their values: "p = 2 bar, V = 4 m³") or symbolic (states are multiples of a
/// reference: "p₂ = 2p₁"). On a symbolic axis the student chooses the scale — where p₁ goes — and the grader checks
/// proportions from the axis origin: 2p₁ must sit twice as far out as p₁.
public struct DiagramAxis: Codable, Sendable, Equatable {
    /// "p", "V", "T", "v".
    public var label: String
    /// "bar", "m^3"; nil for symbolic axes.
    public var unit: String?
    /// The reference a symbolic axis is measured in ("p_1"); nil for numeric axes.
    public var symbol: String?
    /// Range shown. Symbolic axes: in multiples of `symbol` (the grid is unnumbered).
    public var min: Double
    public var max: Double
    /// Spacing of the labelled ticks (numeric axes); nil = chosen from the range.
    public var step: Double?

    public init(label: String, unit: String? = nil, symbol: String? = nil, min: Double = 0, max: Double, step: Double? = nil) {
        self.label = label
        self.unit = unit
        self.symbol = symbol
        self.min = min
        self.max = max
        self.step = step
    }

    public var isSymbolic: Bool { !(symbol ?? "").isEmpty }

    private enum CodingKeys: String, CodingKey { case label, unit, symbol, min, max, step }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        min = try c.decodeIfPresent(Double.self, forKey: .min) ?? 0
        max = try c.decodeIfPresent(Double.self, forKey: .max) ?? 1
        step = try c.decodeIfPresent(Double.self, forKey: .step)
    }
}

/// A numbered state at its coordinates (axis values, or multiples of the axis symbol).
public struct DiagramState: Codable, Sendable, Equatable {
    public var id: String
    public var x: Double
    public var y: Double

    public init(id: String, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// The path a process follows between two states.
public enum DiagramPath: String, Codable, Sendable, Equatable {
    /// Vertical line (constant x, e.g. constant volume on p–V).
    case constantX
    /// Horizontal line (constant y, e.g. constant pressure on p–V).
    case constantY
    /// A straight line at a slant.
    case line
    /// y·xⁿ = constant (pVⁿ = const; n = 1 is the isotherm of an ideal gas, n = −1 a line through the origin).
    case polytropic
    /// Any path between the two states.
    case any
}

public struct DiagramProcess: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var path: DiagramPath
    /// n of y·xⁿ = const, for `.polytropic`.
    public var exponent: Double?

    public init(from: String, to: String, path: DiagramPath, exponent: Double? = nil) {
        self.from = from
        self.to = to
        self.path = path
        self.exponent = exponent
    }

    public var key: String { "\(from)-\(to)" }
}

/// The expected diagram (kept in `AnswerSpec.diagram`, never sent to the page).
public struct DiagramSpec: Codable, Sendable, Equatable {
    public var xAxis: DiagramAxis
    public var yAxis: DiagramAxis
    public var states: [DiagramState]
    public var processes: [DiagramProcess]
    /// The student shades the area under each process that does work.
    public var shadeWork: Bool
    /// Process direction matters (arrows).
    public var directed: Bool

    public init(xAxis: DiagramAxis, yAxis: DiagramAxis, states: [DiagramState], processes: [DiagramProcess],
                shadeWork: Bool = false, directed: Bool = true) {
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.states = states
        self.processes = processes
        self.shadeWork = shadeWork
        self.directed = directed
    }

    private enum CodingKeys: String, CodingKey { case xAxis, yAxis, states, processes, shadeWork, directed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xAxis = try c.decode(DiagramAxis.self, forKey: .xAxis)
        yAxis = try c.decode(DiagramAxis.self, forKey: .yAxis)
        states = try c.decodeIfPresent([DiagramState].self, forKey: .states) ?? []
        processes = try c.decodeIfPresent([DiagramProcess].self, forKey: .processes) ?? []
        shadeWork = try c.decodeIfPresent(Bool.self, forKey: .shadeWork) ?? false
        directed = try c.decodeIfPresent(Bool.self, forKey: .directed) ?? true
    }

    /// What the page shows: the axes, the states to place and whether to shade — never where they go.
    public var setup: DiagramSetup {
        DiagramSetup(xAxis: xAxis, yAxis: yAxis, stateIds: states.map(\.id), shadeWork: shadeWork)
    }
}

/// The student-facing part of a diagram question.
public struct DiagramSetup: Codable, Sendable, Equatable {
    public var xAxis: DiagramAxis
    public var yAxis: DiagramAxis
    public var stateIds: [String]
    public var shadeWork: Bool
}

/// What the student drew (sent by the page as JSON in the part's input).
public struct DiagramAnswer: Codable, Sendable, Equatable {
    public struct Process: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
        /// "line" (straight) or "curve" (y·xⁿ = const with `n`).
        public var path: String
        public var n: Double?

        public init(from: String, to: String, path: String, n: Double? = nil) {
            self.from = from
            self.to = to
            self.path = path
            self.n = n
        }

        public var key: String { "\(from)-\(to)" }
    }

    public var states: [DiagramState]
    public var processes: [Process]
    public var shaded: [String]

    public init(states: [DiagramState], processes: [Process], shaded: [String] = []) {
        self.states = states
        self.processes = processes
        self.shaded = shaded
    }

    private enum CodingKeys: String, CodingKey { case states, processes, shaded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        states = try c.decodeIfPresent([DiagramState].self, forKey: .states) ?? []
        processes = try c.decodeIfPresent([Process].self, forKey: .processes) ?? []
        shaded = try c.decodeIfPresent([String].self, forKey: .shaded) ?? []
    }

    public static func decode(_ json: String) -> DiagramAnswer? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(DiagramAnswer.self, from: Data(trimmed.utf8))
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// A readable account of the drawing ("States 1 (1, 2), 2 (3, 2); processes 1→2 straight"), for the results
    /// sheet and the tutor.
    public static func describe(_ json: String) -> String {
        guard let answer = decode(json), !answer.states.isEmpty else { return "" }
        func number(_ v: Double) -> String {
            let rounded = (v * 1000).rounded() / 1000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        var text = "States " + answer.states.map { "\($0.id) (\(number($0.x)), \(number($0.y)))" }.joined(separator: ", ")
        if !answer.processes.isEmpty {
            text += "; processes " + answer.processes.map { process in
                let shape = process.path == "curve" ? "curve n = \(number(process.n ?? 1))" : "straight"
                return "\(process.from)→\(process.to) \(shape)"
            }.joined(separator: ", ")
        }
        if !answer.shaded.isEmpty { text += "; shaded " + answer.shaded.joined(separator: ", ") }
        return text
    }
}

// MARK: - Validation

extension DiagramSpec {
    /// Why this spec cannot be graded (empty when it can): the states must exist, sit on the axes, and agree with
    /// the processes joining them (a constant-x process keeps x, y·xⁿ = const holds at both ends).
    public var problems: [String] {
        var found: [String] = []
        let ids = states.map(\.id)
        if ids.isEmpty { found.append("no states") }
        if Set(ids).count != ids.count { found.append("duplicate state ids") }
        if !(xAxis.max > xAxis.min) || !(yAxis.max > yAxis.min) { found.append("empty axis range") }
        let byId = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for state in states {
            if state.x < xAxis.min || state.x > xAxis.max || state.y < yAxis.min || state.y > yAxis.max {
                found.append("state \(state.id) is off the axes")
            }
        }
        let xTol = 0.02 * (xAxis.max - xAxis.min), yTol = 0.02 * (yAxis.max - yAxis.min)
        for process in processes {
            guard let a = byId[process.from], let b = byId[process.to] else {
                found.append("process \(process.key) joins a missing state")
                continue
            }
            switch process.path {
            case .constantX where abs(a.x - b.x) > xTol:
                found.append("process \(process.key) is constant-x but x changes")
            case .constantY where abs(a.y - b.y) > yTol:
                found.append("process \(process.key) is constant-y but y changes")
            case .polytropic:
                let n = process.exponent ?? 1
                guard a.x > 0, b.x > 0 else { found.append("process \(process.key) curve needs positive x"); break }
                let ca = a.y * pow(a.x, n), cb = b.y * pow(b.x, n)
                if abs(ca - cb) > 0.03 * max(abs(ca), abs(cb)) { found.append("process \(process.key) ends are not on one y·xⁿ curve") }
            default:
                break
            }
        }
        return found
    }

    /// The drawing that answers this spec exactly (used to check a spec grades itself as correct).
    public var referenceAnswer: DiagramAnswer {
        DiagramAnswer(
            states: states,
            processes: processes.map { process in
                process.path == .polytropic
                    ? .init(from: process.from, to: process.to, path: "curve", n: process.exponent ?? 1)
                    : .init(from: process.from, to: process.to, path: "line")
            },
            shaded: shadeWork ? processes.filter { $0.path != .constantX }.map(\.key) : []
        )
    }

    /// Valid and self-consistent: the reference drawing grades as correct.
    public var isUsable: Bool {
        problems.isEmpty && DiagramGrader.grade(student: referenceAnswer.json, expected: self).outcome == .correct
    }
}

extension Question {
    /// Diagram parts whose spec is missing or unusable become free-response parts (their rubric stays), so a bad
    /// spec can never mark a correct drawing wrong.
    public func withUsableDiagrams() -> Question {
        var copy = self
        for index in copy.parts.indices where copy.parts[index].answerKind == .diagram {
            if copy.parts[index].answer.diagram?.isUsable != true {
                copy.parts[index].answerKind = .freeResponse
                copy.parts[index].answer.diagram = nil
            }
        }
        return copy
    }
}

// MARK: - Grading

/// Grades a drawn diagram against its spec: every state in place (numeric axes by value, symbolic axes by
/// proportion under the student's own scale), every process present, pointing the right way and following the right
/// kind of path, and (when asked) the work areas shaded. Messages name what is off, never where it belongs.
public enum DiagramGrader {
    /// Position tolerance on a numeric axis, as a fraction of the axis span.
    public static let numericTolerance = 0.03
    /// Position tolerance on a symbolic axis, as a fraction of the largest expected coordinate (in the student's scale).
    public static let symbolicTolerance = 0.05
    /// Tolerance on a curve's exponent n.
    public static let exponentTolerance = 0.1

    public static func grade(student json: String, expected spec: DiagramSpec?) -> Verdict {
        guard let spec else { return GradingRules.missingExpectedVerdict }
        guard let answer = DiagramAnswer.decode(json), !answer.states.isEmpty else {
            return Verdict(outcome: .unparseable, message: "Place the states on the grid.", canonicalStudent: nil, canonicalExpected: nil)
        }
        var problems: [String] = []
        let placed = Dictionary(answer.states.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        // States
        let missing = spec.states.filter { placed[$0.id] == nil }.map(\.id)
        if !missing.isEmpty {
            problems.append(missing.count == 1 ? "State \(missing[0]) isn't on the diagram." : "States \(list(missing)) aren't on the diagram.")
        }
        let known = Set(spec.states.map(\.id))
        let extra = answer.states.map(\.id).filter { !known.contains($0) }
        if !extra.isEmpty { problems.append("State \(list(extra)) isn't part of this question.") }

        let pairs = spec.states.compactMap { expected in placed[expected.id].map { (expected, $0) } }
        let xFit = fit(spec.xAxis, expected: pairs.map { $0.0.x }, student: pairs.map { $0.1.x })
        let yFit = fit(spec.yAxis, expected: pairs.map { $0.0.y }, student: pairs.map { $0.1.y })
        var offX: [String] = [], offY: [String] = []
        for (expected, student) in pairs {
            if abs(student.x - xFit.map(expected.x)) > xFit.tolerance { offX.append(expected.id) }
            if abs(student.y - yFit.map(expected.y)) > yFit.tolerance { offY.append(expected.id) }
        }
        if !offX.isEmpty { problems.append(positionMessage(offX, axis: spec.xAxis)) }
        if !offY.isEmpty { problems.append(positionMessage(offY, axis: spec.yAxis)) }

        // Processes
        let drawn = answer.processes
        for process in spec.processes {
            let forward = drawn.first { $0.from == process.from && $0.to == process.to }
            let backward = drawn.first { $0.from == process.to && $0.to == process.from }
            guard let found = forward ?? backward else {
                problems.append("Process \(process.from)–\(process.to) is missing.")
                continue
            }
            if forward == nil, spec.directed {
                problems.append("Process \(process.from)–\(process.to) points the wrong way.")
            }
            if !pathMatches(found, expected: process, states: placed, spec: spec, xTolerance: xFit.tolerance, yTolerance: yFit.tolerance) {
                problems.append("Process \(process.from)–\(process.to) should follow a different kind of path.")
            }
        }
        let expectedPairs = Set(spec.processes.map { pairKey($0.from, $0.to) })
        let extraProcesses = drawn.filter { !expectedPairs.contains(pairKey($0.from, $0.to)) }.map { "\($0.from)–\($0.to)" }
        if !extraProcesses.isEmpty { problems.append("Process \(list(extraProcesses)) isn't part of this question.") }

        // Work areas
        if spec.shadeWork {
            let expectedShaded = Set(spec.processes.filter { $0.path != .constantX }.map { pairKey($0.from, $0.to) })
            let shaded = Set(answer.shaded.compactMap { key -> String? in
                let ends = key.split(separator: "-").map(String.init)
                return ends.count == 2 ? pairKey(ends[0], ends[1]) : nil
            })
            if shaded != expectedShaded {
                problems.append("The shaded work areas don't match the processes that do work.")
            }
        }

        guard problems.isEmpty else {
            let shown = problems.prefix(3).joined(separator: " ")
            let more = problems.count > 3 ? " (and \(problems.count - 3) more)" : ""
            return Verdict(outcome: .incorrect, message: shown + more, canonicalStudent: nil, canonicalExpected: nil)
        }
        return Verdict(outcome: .correct, message: "Correct.", canonicalStudent: nil, canonicalExpected: nil)
    }

    /// Maps expected coordinates into the student's: identity on a numeric axis, the least-squares scale through the
    /// origin on a symbolic one.
    struct AxisFit {
        var scale: Double
        var tolerance: Double
        func map(_ value: Double) -> Double { value * scale }
    }

    static func fit(_ axis: DiagramAxis, expected: [Double], student: [Double]) -> AxisFit {
        guard axis.isSymbolic else {
            return AxisFit(scale: 1, tolerance: max(numericTolerance * (axis.max - axis.min), 1e-9))
        }
        let numerator = zip(expected, student).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = expected.reduce(0) { $0 + $1 * $1 }
        let scale = denominator > 0 && numerator > 0 ? numerator / denominator : 1
        let largest = expected.map(abs).max() ?? 1
        return AxisFit(scale: scale, tolerance: max(symbolicTolerance * scale * max(largest, 1), 1e-9))
    }

    static func pathMatches(_ drawn: DiagramAnswer.Process, expected: DiagramProcess, states: [String: DiagramState],
                            spec: DiagramSpec, xTolerance: Double, yTolerance: Double) -> Bool {
        guard let a = states[drawn.from], let b = states[drawn.to] else { return false }
        let horizontal = abs(a.y - b.y) <= yTolerance
        let vertical = abs(a.x - b.x) <= xTolerance
        let straight = drawn.path != "curve"
        let n = drawn.n ?? 1
        switch expected.path {
        case .any:
            return true
        case .constantX:
            return straight && vertical
        case .constantY:
            return (straight && horizontal) || (!straight && abs(n) <= exponentTolerance && horizontal)
        case .line:
            return straight && !horizontal && !vertical
        case .polytropic:
            let target = expected.exponent ?? 1
            if abs(target) <= exponentTolerance { return horizontal }
            if !straight { return abs(n - target) <= exponentTolerance }
            // pV⁻¹ = const is a straight line through the origin.
            guard abs(target + 1) <= exponentTolerance, !horizontal, !vertical,
                  abs(a.x) > xTolerance, abs(b.x) > xTolerance else { return false }
            let slopeA = a.y / a.x, slopeB = b.y / b.x
            return abs(slopeA - slopeB) <= 0.08 * max(abs(slopeA), abs(slopeB))
        }
    }

    private static func pairKey(_ a: String, _ b: String) -> String { a < b ? "\(a)-\(b)" : "\(b)-\(a)" }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    private static func positionMessage(_ ids: [String], axis: DiagramAxis) -> String {
        let name = axis.label.isEmpty ? "that axis" : "the \(axis.label) axis"
        let states = ids.count == 1 ? "State \(ids[0]) is" : "States \(list(ids)) are"
        if axis.isSymbolic {
            return "\(states) not in proportion on \(name) (check the multiples of \(axis.symbol ?? "the reference"))."
        }
        return "\(states) not at the right value on \(name)."
    }
}
