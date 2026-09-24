import Foundation

/// A concrete value drawn for one template parameter.
public enum TemplateValue: Sendable, Equatable {
    case int(Int)
    case real(Double, decimals: Int)
    case choice(String)

    /// The value as it is written into stems, prompts and answer expressions.
    public var rendered: String {
        switch self {
        case .int(let n): return String(n)
        case .real(let v, let decimals): return TemplateFormatting.render(v, decimals: decimals)
        case .choice(let s): return s
        }
    }

    /// The numeric value, or `nil` for choices.
    public var numeric: Double? {
        switch self {
        case .int(let n): return Double(n)
        case .real(let v, _): return v
        case .choice: return nil
        }
    }

    /// The value the engine substitutes for the bare parameter name (numbers stay numbers, choices become symbols).
    var jsonValue: JSONValue {
        switch self {
        case .int(let n): return .number(Double(n))
        case .real(let v, _): return .number(v)
        case .choice(let s): return .string(s)
        }
    }
}

/// Placeholder substitution for template text. `{a}` is replaced by the parameter's rendered value with the
/// formatting rules students expect in printed mathematics:
/// - a negative value after `+` folds the sign (`3x + {a}` → `3x - 3`), after `-` it flips (`- -3` → `+ 3`),
///   after a multiplicative operator or by juxtaposition it is parenthesised (`2 \cdot {a}` → `2 \cdot (-3)`);
/// - a coefficient of exactly 1 is dropped in front of a variable, a function or a bracket (`{a}x` → `x`,
///   `{a}x` with −1 → `-x`);
/// - after `^` or `_` the value is wrapped in braces so exponents stay well-formed.
public enum TemplateFormatting {
    private static let placeholderPattern = "\\{([A-Za-z_][A-Za-z0-9_]*)\\}"
    private static let placeholderRegex: NSRegularExpression? = try? NSRegularExpression(pattern: placeholderPattern)

    /// LaTeX commands that act as binary operators (a value after them is an operand, and a value before them is
    /// not a coefficient).
    private static let operatorCommands: Set<String> = [
        "cdot", "times", "div", "pm", "mp", "le", "ge", "ne", "leq", "geq", "neq", "lt", "gt", "to", "in", "notin",
        "right", "end", "quad", "qquad", "text", "\\", ",", ";", "!", ":",
    ]
    private static let relationCommands: Set<String> = ["le", "ge", "ne", "leq", "geq", "neq", "lt", "gt", "to", "in", "notin"]
    private static let multiplicativeCommands: Set<String> = ["cdot", "times", "div"]
    private static let openingCharacters: Set<Character> = ["=", "(", "[", "{", ",", ";", ":", "<", ">", "|", "$", "&"]

    /// Replaces every `{name}` whose name is a key of `values`; other braces are left untouched.
    public static func substitute(_ text: String, values: [String: TemplateValue]) -> String {
        guard let regex = placeholderRegex, !values.isEmpty else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1))
            guard let value = values[name] else { continue }
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let following = source.substring(from: match.range.location + match.range.length)
            // `{n}` that is a command's argument (`\frac{1}{n}`, `\sqrt{n}`) keeps its braces: `\frac{1000000}2287`
            // would read as (1000000/2)·287.
            let before = output
            let isArgument = before.hasSuffix("}")
                || before.range(of: #"\\(frac|dfrac|tfrac|cfrac|sqrt|binom|dbinom|tbinom)\s*$"#, options: .regularExpression) != nil
            output = insert(value, after: output, before: following)
            if isArgument, output.hasPrefix(before) {
                output = before + "{" + output.dropFirst(before.count) + "}"
            }
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    /// Renders a real number with at most `decimals` fractional digits, trailing zeros removed (`2.50` → `2.5`,
    /// `3.0` → `3`).
    public static func render(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        let clamped = max(0, min(decimals, 12))
        var text = String(format: "%.\(clamped)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text
    }

    /// Names of the placeholders that appear in `text`.
    public static func placeholderNames(in text: String) -> [String] {
        guard let regex = placeholderRegex else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range(at: 1))
        }
    }

    // MARK: - Context-sensitive insertion

    private enum Preceding { case plus, minus, opening, multiplicative, exponent, juxtaposed }

    private static func insert(_ value: TemplateValue, after prefix: String, before following: String) -> String {
        guard let numeric = value.numeric else { return prefix + value.rendered }
        let trimmedPrefix = String(prefix.reversed().drop(while: { $0.isWhitespace }).reversed())
        let gap = String(prefix.dropFirst(trimmedPrefix.count))
        let preceding = classify(trimmedPrefix)
        let rendered = value.rendered
        let magnitude = rendered.hasPrefix("-") ? String(rendered.dropFirst()) : rendered
        if preceding == .exponent { return prefix + "{" + rendered + "}" }
        let dropsUnit = abs(numeric) == 1 && startsCoefficientTarget(following)
        let magnitudeText = dropsUnit ? "" : magnitude
        guard numeric < 0 else {
            return prefix + magnitudeText
        }
        switch preceding {
        case .plus:
            return String(trimmedPrefix.dropLast()) + "-" + gap + magnitudeText
        case .minus:
            return String(trimmedPrefix.dropLast()) + "+" + gap + magnitudeText
        case .opening:
            return prefix + "-" + magnitudeText
        case .multiplicative, .juxtaposed, .exponent:
            return prefix + "(-" + magnitude + ")"
        }
    }

    private static func classify(_ trimmedPrefix: String) -> Preceding {
        guard let last = trimmedPrefix.last else { return .opening }
        if last == "^" || last == "_" { return .exponent }
        if last == "+" { return .plus }
        if last == "-" { return .minus }
        if last == "*" || last == "/" { return .multiplicative }
        if openingCharacters.contains(last) { return .opening }
        if let command = trailingCommand(of: trimmedPrefix) {
            if multiplicativeCommands.contains(command) { return .multiplicative }
            if relationCommands.contains(command) { return .opening }
        }
        return .juxtaposed
    }

    /// The name of a LaTeX command that the text ends with (`3 \cdot` → `cdot`), if any.
    private static func trailingCommand(of text: String) -> String? {
        var letters = ""
        for character in text.reversed() {
            if character.isLetter { letters.insert(character, at: letters.startIndex); continue }
            if character == "\\" { return letters.isEmpty ? nil : letters }
            return nil
        }
        return nil
    }

    /// True when the text starts with something a numeric coefficient multiplies: a variable, a bracket, or a
    /// LaTeX command that is not an operator (`\sqrt`, `\sin`, `\pi`, `\left`, `\frac`).
    private static func startsCoefficientTarget(_ following: String) -> Bool {
        let trimmed = following.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first else { return false }
        if first.isLetter || first == "(" { return true }
        guard first == "\\" else { return false }
        let name = String(trimmed.dropFirst().prefix(while: { $0.isLetter }))
        if name.isEmpty {
            let symbol = String(trimmed.dropFirst().prefix(1))
            return !operatorCommands.contains(symbol)
        }
        return !operatorCommands.contains(name)
    }
}

/// Draws parameter values with a seeded generator.
struct TemplateSampler {
    /// Attempts per parameter before its exclusion list is considered impossible to satisfy.
    static let exclusionRetries = 64

    static func draw(_ params: [TemplateParam], using rng: inout SeededRandom) throws -> [String: TemplateValue] {
        var values: [String: TemplateValue] = [:]
        for param in params {
            values[param.name] = try draw(param, using: &rng)
        }
        return values
    }

    private static func draw(_ param: TemplateParam, using rng: inout SeededRandom) throws -> TemplateValue {
        for _ in 0..<exclusionRetries {
            let candidate = try drawOnce(param, using: &rng)
            if !isExcluded(candidate, by: param.exclude) { return candidate }
        }
        throw ThubanError.invalidTemplate(["Parameter '\(param.name)': no value outside its exclusion list could be drawn."])
    }

    private static func drawOnce(_ param: TemplateParam, using rng: inout SeededRandom) throws -> TemplateValue {
        switch param.kind {
        case let .int(min, max):
            guard min <= max else {
                throw ThubanError.invalidTemplate(["Parameter '\(param.name)': min \(min) is greater than max \(max)."])
            }
            return .int(rng.nextInt(in: min...max))
        case let .real(min, max, decimals):
            guard min <= max, min.isFinite, max.isFinite else {
                throw ThubanError.invalidTemplate(["Parameter '\(param.name)': invalid real range \(min)…\(max)."])
            }
            let scale = pow(10.0, Double(Swift.max(0, Swift.min(decimals, 12))))
            let raw = rng.nextDouble(in: min...max)
            return .real((raw * scale).rounded() / scale, decimals: decimals)
        case .choice(let options):
            guard !options.isEmpty else {
                throw ThubanError.invalidTemplate(["Parameter '\(param.name)': choice has no options."])
            }
            return .choice(options[rng.nextInt(in: 0...(options.count - 1))])
        }
    }

    private static func isExcluded(_ value: TemplateValue, by exclusions: [Double]) -> Bool {
        guard let numeric = value.numeric else { return false }
        return exclusions.contains { abs($0 - numeric) < 1e-9 }
    }
}
