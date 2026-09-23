import SwiftUI
import ThubanCore

/// Edits what several questions share: the type and the difficulty. Each field is left alone unless its
/// "Change" switch is on, so a batch never clobbers values the student did not mean to touch. Saves through the
/// caller (`ClassSession.save(questions:)`).
struct BatchEditSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var questions: [Question]
    /// The class's other types, offered as a menu next to the type field.
    var knownTypes: [String]
    var onSave: ([Question]) -> Void

    @State private var changeType = false
    @State private var type: String
    @State private var changeDifficulty = false
    @State private var difficulty: Int

    init(questions: [Question], knownTypes: [String] = [], onSave: @escaping ([Question]) -> Void) {
        self.questions = questions
        self.knownTypes = knownTypes
        self.onSave = onSave
        // Prefill with the shared value when every question agrees.
        let types = Set(questions.map(\.type))
        _type = State(initialValue: types.count == 1 ? (types.first ?? "") : "")
        let difficulties = Set(questions.map(\.difficulty))
        _difficulty = State(initialValue: difficulties.count == 1 ? (difficulties.first ?? 3) : 3)
    }

    private var summary: String {
        let types = Set(questions.map(\.type))
        let typeText = types.count == 1 ? "all “\(questions[0].typeLabel)”" : "\(types.count) different types"
        return "\(questions.count) questions selected · \(typeText)"
    }

    var body: some View {
        ModalCard(title: "Edit \(questions.count) questions", width: 520) {
            VStack(alignment: .leading, spacing: 16.z) {
                Text(summary)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)

                LabeledField("Type") {
                    HStack(spacing: 8.z) {
                        Toggle("Change", isOn: $changeType)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        TextField("Initial value problems", text: $type)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!changeType)
                            .onChange(of: type) { _, _ in changeType = true }
                        if !knownTypes.isEmpty {
                            Menu {
                                ForEach(knownTypes, id: \.self) { known in
                                    Button(known) { type = known; changeType = true }
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

                LabeledField("Difficulty") {
                    HStack(spacing: 8.z) {
                        Toggle("Change", isOn: $changeDifficulty)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        Picker("Difficulty", selection: $difficulty) {
                            ForEach(1...5, id: \.self) { level in
                                Text(String(repeating: "●", count: level)).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(!changeDifficulty)
                        .onChange(of: difficulty) { _, _ in changeDifficulty = true }
                    }
                }

                Text("Stems, parts and answers are edited one question at a time.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkFaintColor)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Apply to \(questions.count)") { apply() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!changeType && !changeDifficulty)
        }
    }

    private func apply() {
        let edited = questions.map { question in
            var copy = question
            if changeType { copy.type = type }
            if changeDifficulty { copy.difficulty = difficulty }
            return copy
        }
        onSave(edited)
        dismiss()
    }
}
