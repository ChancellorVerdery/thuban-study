import Foundation

/// Turns a `MathTemplate` into a concrete `QuestionInstance`: seeded sampling, constraint filtering, placeholder
/// substitution and engine evaluation of the answer expressions. Runs inside the `MathEngine` actor.
struct TemplateInstantiator {
    let runtime: MathEngineRuntime

    /// Parameter draws attempted before the constraints are declared unsatisfiable.
    static let maxDraws = 200

    /// Seeds used by `validate` so the import pipeline sees three different draws.
    static let trialSeeds = ["0000002a", "00c0ffee", "deadbeef"]

    /// Parameter names that collide with engine constants and would silently change meaning.
    static let reservedNames: Set<String> = ["e", "i", "pi", "Pi", "ExponentialE", "ImaginaryUnit", "True", "False", "Nothing"]

    // MARK: - Instantiation

    func instantiate(_ template: MathTemplate, seed: String, questionId: QuestionID) throws -> QuestionInstance {
        var rng = SeededRandom(seed: seed)
        let values = try satisfyingDraw(template, rng: &rng)
        let parameters = values.mapValues(\.jsonValue)
        let parts = try template.parts.map { part in
            try instantiatePart(part, values: values, parameters: parameters)
        }
        return QuestionInstance(
            questionId: questionId,
            seed: seed,
            stem: TemplateFormatting.substitute(template.stem, values: values),
            parts: parts,
            params: values.mapValues(\.rendered)
        )
    }

    /// The template's answers at its parameters' original values (`TemplateParam.original`), by part id; nil when
    /// a numeric parameter has no original value.
    func answersAtOriginals(_ template: MathTemplate) throws -> [String: String]? {
        var values: [String: TemplateValue] = [:]
        for param in template.params {
            switch param.kind {
            case .int:
                guard let original = param.original else { return nil }
                values[param.name] = original == original.rounded() ? .int(Int(original)) : .real(original, decimals: 6)
            case .real(_, _, let decimals):
                guard let original = param.original else { return nil }
                values[param.name] = .real(original, decimals: max(decimals, Self.decimals(of: original)))
            case .choice(let options):
                guard let first = options.first else { return nil }
                values[param.name] = .choice(first)
            }
        }
        let parameters = values.mapValues(\.jsonValue)
        var answers: [String: String] = [:]
        for part in template.parts {
            answers[part.id] = try instantiatePart(part, values: values, parameters: parameters).answerLatex
        }
        return answers
    }

    static func decimals(of value: Double) -> Int {
        var decimals = 0, scaled = value
        while decimals < 6, abs(scaled - scaled.rounded()) > 1e-9 { scaled *= 10; decimals += 1 }
        return decimals
    }

    private func satisfyingDraw(_ template: MathTemplate, rng: inout SeededRandom) throws -> [String: TemplateValue] {
        let constraints = template.constraints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for _ in 0..<Self.maxDraws {
            let values = try TemplateSampler.draw(template.params, using: &rng)
            if constraints.isEmpty { return values }
            if try constraintsHold(constraints, values: values) { return values }
        }
        throw ThubanError.invalidTemplate([
            "No parameter draw satisfied the constraints \(constraints.joined(separator: ", ")) in \(Self.maxDraws) tries.",
        ])
    }

    private func constraintsHold(_ constraints: [String], values: [String: TemplateValue]) throws -> Bool {
        let request = ConstraintRequest(constraints: constraints, params: values.mapValues(\.jsonValue))
        let response = try runtime.call("checkConstraints", request, as: ConstraintResponse.self)
        let problems = response.results.compactMap(\.error)
        if !problems.isEmpty { throw ThubanError.invalidTemplate(problems) }
        return response.results.allSatisfy(\.ok)
    }

    private func instantiatePart(_ part: TemplatePart, values: [String: TemplateValue], parameters: [String: JSONValue]) throws -> InstancePart {
        let expression = TemplateFormatting.substitute(part.answerExpr, values: values)
        let answer = try evaluateAnswer(expression, partId: part.id, parameters: parameters)
        return InstancePart(
            id: part.id,
            prompt: TemplateFormatting.substitute(part.prompt, values: values),
            answerLatex: answer,
            answerKind: part.answerKind,
            choices: part.choices?.map { TemplateFormatting.substitute($0, values: values) },
            conditions: part.conditions
        )
    }

    private func evaluateAnswer(_ expression: String, partId: String, parameters: [String: JSONValue]) throws -> String {
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThubanError.invalidTemplate(["Part '\(partId)': answerExpr is empty."])
        }
        do {
            let response = try runtime.call("instantiateAnswer", AnswerRequest(expr: expression, params: parameters), as: LatexResponse.self)
            return response.latex
        } catch ThubanError.engine(let detail) {
            throw ThubanError.invalidTemplate(["Part '\(partId)': \(detail)"])
        }
    }

    // MARK: - Validation

    func validate(_ template: MathTemplate) -> [String] {
        var errors = structuralErrors(template)
        errors += expressionErrors(template)
        if errors.isEmpty {
            errors += trialErrors(template)
        }
        return errors.uniqued()
    }

    private func structuralErrors(_ template: MathTemplate) -> [String] {
        var errors: [String] = []
        if template.parts.isEmpty { errors.append("Template has no parts.") }
        var seenNames: Set<String> = []
        for param in template.params {
            let name = param.name
            if name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                errors.append("Parameter name '\(name)' is not a valid identifier.")
            } else if Self.reservedNames.contains(name) {
                errors.append("Parameter name '\(name)' collides with an engine constant.")
            }
            if !seenNames.insert(name).inserted { errors.append("Parameter '\(name)' is declared twice.") }
            errors += kindErrors(param)
        }
        var seenParts: Set<String> = []
        for part in template.parts {
            if part.id.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("A part has an empty id.") }
            if !seenParts.insert(part.id).inserted { errors.append("Part id '\(part.id)' is used twice.") }
            if part.answerExpr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Part '\(part.id)': answerExpr is empty.")
            }
        }
        return errors
    }

    /// Widest integer range a template parameter may declare (`max - min`).
    static let maxIntRangeWidth = 1_000_000_000_000

    private func kindErrors(_ param: TemplateParam) -> [String] {
        switch param.kind {
        case let .int(min, max):
            guard min <= max else { return ["Parameter '\(param.name)': min \(min) is greater than max \(max)."] }
            // Never materialise the range: an agent-written `1…1e9` must not allocate gigabytes here.
            let (width, overflow) = max.subtractingReportingOverflow(min)
            guard !overflow, width < Self.maxIntRangeWidth else {
                return ["Parameter '\(param.name)': the range \(min)…\(max) is too wide (at most \(Self.maxIntRangeWidth) values)."]
            }
            let excludedInRange = Set(param.exclude.compactMap { value -> Int? in
                guard value.isFinite, abs(value - value.rounded()) < 1e-9, let int = Int(exactly: value.rounded()) else { return nil }
                return (min...max).contains(int) ? int : nil
            }).count
            return excludedInRange > width ? ["Parameter '\(param.name)': every value in \(min)…\(max) is excluded."] : []
        case let .real(min, max, decimals):
            var errors: [String] = []
            if !(min <= max) || !min.isFinite || !max.isFinite { errors.append("Parameter '\(param.name)': invalid real range.") }
            if decimals < 0 || decimals > 12 { errors.append("Parameter '\(param.name)': decimals must be between 0 and 12.") }
            return errors
        case .choice(let options):
            return options.isEmpty ? ["Parameter '\(param.name)': choice has no options."] : []
        }
    }

    private func expressionErrors(_ template: MathTemplate) -> [String] {
        var errors: [String] = []
        let names = Set(template.params.map(\.name))
        for constraint in template.constraints where !constraint.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let check = try? runtime.call("validateExpression", ExpressionRequest(latex: constraint), as: ExpressionResponse.self) else {
                errors.append("Constraint '\(constraint)' could not be checked.")
                continue
            }
            if !check.valid {
                errors.append("Constraint '\(constraint)' is not valid LaTeX.")
            } else {
                let unknown = check.freeVariables.filter { !names.contains($0) }
                if !unknown.isEmpty {
                    errors.append("Constraint '\(constraint)' uses unknown parameter(s): \(unknown.joined(separator: ", ")).")
                }
            }
        }
        for part in template.parts where !part.answerExpr.trimmingCharacters(in: .whitespaces).isEmpty {
            let placeholdersRemoved = TemplateFormatting.substitute(part.answerExpr, values: Self.placeholderStandIns(template))
            guard let check = try? runtime.call("validateExpression", ExpressionRequest(latex: placeholdersRemoved), as: ExpressionResponse.self) else {
                errors.append("Part '\(part.id)': answerExpr could not be checked.")
                continue
            }
            if !check.valid { errors.append("Part '\(part.id)': answerExpr '\(part.answerExpr)' is not valid LaTeX.") }
        }
        return errors
    }

    /// Placeholder values used only to check that answer expressions parse.
    private static func placeholderStandIns(_ template: MathTemplate) -> [String: TemplateValue] {
        var values: [String: TemplateValue] = [:]
        for param in template.params {
            switch param.kind {
            case .int: values[param.name] = .int(2)
            case .real: values[param.name] = .real(2.5, decimals: 1)
            case .choice(let options): values[param.name] = .choice(options.first ?? "x")
            }
        }
        return values
    }

    private func trialErrors(_ template: MathTemplate) -> [String] {
        var errors: [String] = []
        for seed in Self.trialSeeds {
            do {
                let instance = try instantiate(template, seed: seed, questionId: QuestionID(raw: "validation"))
                errors += instanceErrors(instance)
            } catch ThubanError.invalidTemplate(let problems) {
                errors += problems
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return errors
    }

    private func instanceErrors(_ instance: QuestionInstance) -> [String] {
        var errors: [String] = []
        for part in instance.parts {
            let answer = part.answerLatex.trimmingCharacters(in: .whitespaces)
            if answer.isEmpty { errors.append("Part '\(part.id)': the answer evaluated to nothing.") }
            if answer.contains("\\error") { errors.append("Part '\(part.id)': the answer evaluated to an error.") }
            if !TemplateFormatting.placeholderNames(in: part.prompt).filter({ instance.params[$0] != nil }).isEmpty {
                errors.append("Part '\(part.id)': a placeholder was left unsubstituted.")
            }
        }
        return errors
    }

    // MARK: - Wire types

    struct ConstraintRequest: Encodable {
        var constraints: [String]
        var params: [String: JSONValue]
    }

    struct ConstraintResponse: Decodable {
        struct Item: Decodable {
            var ok: Bool
            var error: String?
        }
        var results: [Item]
    }

    struct AnswerRequest: Encodable {
        var expr: String
        var params: [String: JSONValue]
    }

    struct LatexResponse: Decodable {
        var latex: String
    }

    struct ExpressionRequest: Encodable {
        var latex: String
    }

    struct ExpressionResponse: Decodable {
        var valid: Bool
        var freeVariables: [String]
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
