import Foundation
import os

/// The app's math engine: a JavaScriptCore-hosted Compute Engine behind an actor. Grades student answers,
/// instantiates math templates with fresh numbers, validates templates for the import pipeline, and evaluates or
/// simplifies LaTeX for the calculator.
///
/// The Compute Engine bundle is loaded once, lazily, on the first call (about 0.2 s); call `warmUp()` at launch to
/// pay that cost early. Every method is safe to call from any task because the actor serializes access to the
/// single `JSContext`.
public actor MathEngine {
    private static let logger = Logger(subsystem: "com.thuban.study", category: "MathEngine")

    private var runtime: MathEngineRuntime?

    /// Creates an engine without loading anything yet.
    public init() {}

    /// Loads the Compute Engine now so the first grading call is fast.
    public func warmUp() async throws {
        _ = try loadedRuntime()
    }

    /// True once the Compute Engine bundle has been loaded.
    public var isLoaded: Bool { runtime != nil }

    // MARK: - Grading

    /// Grades one part. Never throws: engine failures come back as `.needsTutor` so a broken bundle cannot mark a
    /// student wrong.
    public func grade(student latex: String, expected: AnswerSpec, conditions: AnswerConditions, kind: AnswerKind) async -> Verdict {
        switch kind {
        case .freeResponse:
            return GradingRules.tutorVerdict
        case .text, .choice:
            return GradingRules.gradeText(student: latex, expected: expected)
        case .math, .numeric:
            return gradeMath(student: latex, expected: expected, conditions: conditions)
        }
    }

    private func gradeMath(student: String, expected: AnswerSpec, conditions: AnswerConditions) -> Verdict {
        let expectedLatex = expected.latex ?? expected.text
        guard let expectedLatex, !expectedLatex.trimmingCharacters(in: .whitespaces).isEmpty || !expected.alternatives.isEmpty else {
            return GradingRules.missingExpectedVerdict
        }
        let request = GradingRules.GradeRequest(
            student: student,
            expected: expectedLatex,
            alternatives: expected.alternatives,
            conditions: conditions
        )
        do {
            return try loadedRuntime().call("grade", request, as: Verdict.self)
        } catch {
            Self.logger.error("grade failed: \(error.localizedDescription, privacy: .public)")
            return GradingRules.engineFailureVerdict
        }
    }

    // MARK: - Templates

    /// Instantiates a template deterministically for `seed` (a fresh random seed when `nil`). The returned
    /// instance carries a placeholder `questionId`; use `instantiate(_:seed:questionId:)` to set the real one.
    public func instantiate(_ template: MathTemplate, seed: String?) async throws -> QuestionInstance {
        try await instantiate(template, seed: seed, questionId: QuestionID(raw: ""))
    }

    /// Instantiates a template for a specific question. Same seed ⇒ same instance.
    public func instantiate(_ template: MathTemplate, seed: String?, questionId: QuestionID) async throws -> QuestionInstance {
        let resolvedSeed = Self.normalizedSeed(seed)
        let instantiator = TemplateInstantiator(runtime: try loadedRuntime())
        return try instantiator.instantiate(template, seed: resolvedSeed, questionId: questionId)
    }

    /// Checks a template the import agent wrote: structure, constraint and answer syntax, then three trial
    /// instantiations. Returns human-readable problems; empty means valid.
    public func validate(_ template: MathTemplate) async -> [String] {
        do {
            return TemplateInstantiator(runtime: try loadedRuntime()).validate(template)
        } catch {
            return ["The math engine could not be loaded: \(error.localizedDescription)"]
        }
    }

    // MARK: - Calculator

    /// Numerically evaluates LaTeX and returns LaTeX with at most 10 significant digits (`\\frac{2}{3}` →
    /// `0.6666666667`). Symbolic results (unbound variables) come back as simplified LaTeX.
    public func evaluate(_ latex: String) async throws -> String {
        try latexCall("evaluate", latex)
    }

    /// Symbolically simplifies LaTeX.
    public func simplify(_ latex: String) async throws -> String {
        try latexCall("simplify", latex)
    }

    private func latexCall(_ function: String, _ latex: String) throws -> String {
        do {
            return try loadedRuntime().call(function, LatexRequest(latex: latex), as: LatexResult.self).latex
        } catch ThubanError.engine(let detail) where detail == "unparseable" {
            throw ThubanError.parse("'\(latex)' is not a valid expression.")
        }
    }

    // MARK: - Private

    private func loadedRuntime() throws -> MathEngineRuntime {
        if let runtime { return runtime }
        let created = try MathEngineRuntime()
        runtime = created
        return created
    }

    private static func normalizedSeed(_ seed: String?) -> String {
        let trimmed = seed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SeededRandom.newSeedString() : trimmed
    }

    private struct LatexRequest: Encodable { var latex: String }
    private struct LatexResult: Decodable { var latex: String }
}
