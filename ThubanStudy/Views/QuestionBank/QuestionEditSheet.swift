import SwiftUI
import ThubanCore

/// Minimal question editor: stem, source reference, and for each part its prompt, answer and grading conditions.
/// Math-engine questions edit the template (placeholders + answer expressions); the static parts mirror the
/// prompts and conditions so both stay in step. Saves through the caller (`Store.update`).
struct QuestionEditSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var onSave: (Question) -> Void
    /// The class's other types, offered as a menu next to the type field.
    var knownTypes: [String]

    @State private var draft: Question
    @State private var stem: String
    @State private var sourceRef: String
    @State private var type: String
    @State private var parts: [PartDraft]
    @State private var validation: String?

    init(question: Question, knownTypes: [String] = [], onSave: @escaping (Question) -> Void) {
        self.onSave = onSave
        self.knownTypes = knownTypes
        _draft = State(initialValue: question)
        let template = question.kind == .mathTemplate ? question.template : nil
        _stem = State(initialValue: template?.stem ?? question.stem)
        _sourceRef = State(initialValue: question.sourceRef ?? "")
        _type = State(initialValue: question.type)
        _parts = State(initialValue: PartDraft.drafts(for: question))
    }

    private var isTemplate: Bool { draft.kind == .mathTemplate && draft.template != nil }

    var body: some View {
        ModalCard(title: "Edit question", width: 640) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        if isTemplate { Chip.regenerates }
                        if isTemplate {
                            Text("Placeholders like {a} get fresh numbers each time; answers are engine expressions.")
                                .font(ThubanFont.small)
                                .foregroundStyle(theme.inkDimColor)
                        } else {
                            Text("Markdown with $…$ for math. Any algebraically equivalent answer is accepted.")
                                .font(ThubanFont.small)
                                .foregroundStyle(theme.inkDimColor)
                        }
                    }
                    LabeledField("Stem") {
                        EditorBox(text: $stem, minHeight: 84)
                    }
                    LabeledField("Source reference") {
                        TextField("Homework 4 · Q3", text: $sourceRef)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField("Type") {
                        HStack(spacing: 6) {
                            TextField("Initial value problems", text: $type)
                                .textFieldStyle(.roundedBorder)
                            if !knownTypes.isEmpty {
                                Menu {
                                    ForEach(knownTypes, id: \.self) { known in
                                        Button(known) { type = known }
                                    }
                                } label: {
                                    Glyph(.chevronDown, size: 13)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Types already in this class")
                            }
                        }
                    }
                    ForEach($parts) { $part in
                        PartEditor(part: $part, isTemplate: isTemplate)
                    }
                    if let validation {
                        Text(validation)
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.negTextColor)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 520)
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        var question = draft
        let trimmedStem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStem.isEmpty else { validation = "The stem cannot be empty."; return }
        question.sourceRef = sourceRef.trimmingCharacters(in: .whitespaces).nilIfEmpty
        question.type = Question.normalizedType(type)
        if isTemplate, var template = question.template {
            template.stem = trimmedStem
            for draftPart in parts {
                if let index = template.parts.firstIndex(where: { $0.id == draftPart.id }) {
                    template.parts[index].prompt = draftPart.prompt
                    template.parts[index].answerExpr = draftPart.answer
                    template.parts[index].conditions = draftPart.conditions.conditions
                    if draftPart.answerKind == .choice { template.parts[index].choices = draftPart.choiceList }
                }
            }
            question.template = template
            question.stem = trimmedStem
        } else {
            question.stem = trimmedStem
        }
        for draftPart in parts {
            guard let index = question.parts.firstIndex(where: { $0.id == draftPart.id }) else { continue }
            question.parts[index].prompt = draftPart.prompt
            question.parts[index].conditions = draftPart.conditions.conditions
            switch draftPart.answerKind {
            case .text, .choice:
                question.parts[index].answer.text = draftPart.answer.nilIfEmpty
                if draftPart.answerKind == .choice { question.parts[index].choices = draftPart.choiceList }
            case .freeResponse:
                question.parts[index].answer.rubric = draftPart.answer.nilIfEmpty
            case .math, .numeric:
                if !isTemplate { question.parts[index].answer.latex = draftPart.answer.nilIfEmpty }
            }
        }
        onSave(question)
        dismiss()
    }
}

// MARK: - Part draft

/// Editable copy of one part (template or static).
private struct PartDraft: Identifiable {
    var id: String
    var prompt: String
    var answerKind: AnswerKind
    /// LaTeX / engine expression / correct option text / rubric, by `answerKind`.
    var answer: String
    /// One option per line (choice parts).
    var choices: String
    var conditions: ConditionsDraft

    var choiceList: [String] {
        choices.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func drafts(for question: Question) -> [PartDraft] {
        if question.kind == .mathTemplate, let template = question.template {
            return template.parts.map { part in
                PartDraft(id: part.id, prompt: part.prompt, answerKind: part.answerKind, answer: part.answerExpr,
                          choices: (part.choices ?? []).joined(separator: "\n"), conditions: ConditionsDraft(part.conditions))
            }
        }
        return question.parts.map { part in
            let answer: String
            switch part.answerKind {
            case .text, .choice: answer = part.answer.text ?? part.answer.latex ?? ""
            case .freeResponse: answer = part.answer.rubric ?? ""
            case .math, .numeric: answer = part.answer.latex ?? ""
            }
            return PartDraft(id: part.id, prompt: part.prompt, answerKind: part.answerKind, answer: answer,
                             choices: (part.choices ?? []).joined(separator: "\n"), conditions: ConditionsDraft(part.conditions))
        }
    }
}

/// The toggles of `AnswerConditions` plus rounding and units as text.
private struct ConditionsDraft {
    var rounding: String
    var rationalizedDenominator: Bool
    var simplified: Bool
    var factored: Bool
    var expanded: Bool
    var explicit: Bool
    var exactRadicals: Bool
    var units: String
    var custom: [String]

    init(_ conditions: AnswerConditions) {
        rounding = conditions.roundingDecimals.map(String.init) ?? ""
        rationalizedDenominator = conditions.rationalizedDenominator
        simplified = conditions.simplified
        factored = conditions.factored
        expanded = conditions.expanded
        explicit = conditions.explicit
        exactRadicals = conditions.exactRadicals
        units = conditions.units ?? ""
        custom = conditions.custom
    }

    var conditions: AnswerConditions {
        let decimals = Int(rounding.trimmingCharacters(in: .whitespaces))
        return AnswerConditions(
            roundingDecimals: decimals,
            rationalizedDenominator: rationalizedDenominator,
            simplified: simplified,
            factored: factored,
            expanded: expanded,
            explicit: explicit,
            exactRadicals: decimals == nil ? true : exactRadicals,
            units: units.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            custom: custom
        )
    }
}

// MARK: - Part editor

private struct PartEditor: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var part: PartDraft
    var isTemplate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Part (\(part.id))")
                    .font(ThubanFont.display(15))
                    .foregroundStyle(theme.inkColor)
                Chip(answerKindLabel, kind: .neutral)
            }
            LabeledField("Prompt") {
                EditorBox(text: $part.prompt, minHeight: 56)
            }
            LabeledField(answerLabel) {
                if part.answerKind == .freeResponse {
                    EditorBox(text: $part.answer, minHeight: 56)
                } else {
                    TextField(answerPlaceholder, text: $part.answer)
                        .textFieldStyle(.roundedBorder)
                        .font(ThubanFont.mono(13))
                }
            }
            if part.answerKind == .choice {
                LabeledField("Choices (one per line)") {
                    EditorBox(text: $part.choices, minHeight: 64)
                }
            }
            if part.answerKind == .math || part.answerKind == .numeric {
                ConditionsEditor(draft: $part.conditions)
            }
        }
        .padding(14)
        .background(theme.panel2Color.opacity(0.5), in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
    }

    private var answerKindLabel: String {
        switch part.answerKind {
        case .math: return isTemplate ? "Engine expression" : "Math"
        case .numeric: return "Numeric"
        case .text: return "Text"
        case .choice: return "Choice"
        case .freeResponse: return "Free response"
        }
    }

    private var answerLabel: String {
        switch part.answerKind {
        case .freeResponse: return "Rubric (tutor-graded)"
        case .choice: return "Correct option"
        case .text: return "Answer text"
        case .math, .numeric: return isTemplate ? "Answer expression (LaTeX with placeholders)" : "Answer (LaTeX)"
        }
    }

    private var answerPlaceholder: String {
        switch part.answerKind {
        case .choice: return "The correct option, exactly as listed"
        case .text: return "Expected text"
        default: return isTemplate ? "2{a}{b}+3{b}^3" : "\\frac{1}{2}"
        }
    }
}

/// Toggles for the grading conditions, rounding and units.
private struct ConditionsEditor: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var draft: ConditionsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conditions")
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                Toggle("Rationalized denominator", isOn: $draft.rationalizedDenominator)
                Toggle("Simplified", isOn: $draft.simplified)
                Toggle("Fully factored", isOn: $draft.factored)
                Toggle("Expanded", isOn: $draft.expanded)
                Toggle("Solved explicitly", isOn: $draft.explicit)
                Toggle("Exact radicals", isOn: $draft.exactRadicals)
                    .disabled(draft.rounding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .toggleStyle(.checkbox)
            .font(ThubanFont.small)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Round to")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                    TextField("exact", text: $draft.rounding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                    Text("decimals")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                }
                HStack(spacing: 6) {
                    Text("Units")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                    TextField("none", text: $draft.units)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
            if !draft.custom.isEmpty {
                Text("Also: " + draft.custom.joined(separator: " · "))
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }
        }
    }
}

/// A bordered multi-line text box in the control chrome.
private struct EditorBox: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var text: String
    var minHeight: CGFloat = 60

    var body: some View {
        TextEditor(text: $text)
            .font(ThubanFont.body(14))
            .foregroundStyle(theme.inkColor)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
            )
    }
}
