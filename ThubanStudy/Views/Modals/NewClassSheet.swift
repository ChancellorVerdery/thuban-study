import SwiftUI
import ThubanCore

// MARK: - New class

/// Create a class: name, course code, term, tab color, tutor style, and whether to jump straight to Import.
struct NewClassSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var form = NewClassForm()
    @State private var error: String?
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ModalCard(title: "New class", width: 520) {
            VStack(alignment: .leading, spacing: 16) {
                LabeledField("Class name") {
                    TextField("Multivariable Calculus", text: $form.name)
                        .thubanField()
                        .focused($nameFocused)
                        .onSubmit { save() }
                        .accessibilityLabel("Class name")
                }

                HStack(alignment: .top, spacing: 12) {
                    LabeledField("Course code · optional") {
                        TextField("MATH 2210", text: $form.courseCode)
                            .thubanField()
                            .accessibilityLabel("Course code")
                    }
                    LabeledField("Term") {
                        TermPicker(choice: $form.termChoice, custom: $form.customTerm)
                    }
                }

                LabeledField("Tab color") {
                    TintRow(options: ClassTintOption.options(for: theme), selectedId: $form.tintId)
                }

                LabeledField("Tutor style") {
                    VStack(alignment: .leading, spacing: 8) {
                        SegmentedPicker(
                            selection: $form.tutorStyle,
                            options: TutorStyle.allCases.map { SegmentOption($0, $0.displayName) },
                            fillsWidth: true
                        )
                        Text(form.tutorStyle.summary)
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.inkDimColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("Import documents right after creating", isOn: $form.importAfterCreate)
                    .toggleStyle(.checkbox)
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkColor)
                    .tint(theme.accentColor)

                if let error {
                    Text(error)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.negTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button(isSaving ? "Creating…" : "Create class") { save() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isValid || isSaving)
        }
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard form.isValid, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            do {
                var created = try await app.createClass(
                    name: form.name,
                    courseCode: form.courseCode,
                    term: form.term,
                    tutorStyle: form.tutorStyle
                )
                if let tint = form.tintHex(for: theme) {
                    created.tint = tint
                    try await app.updateClass(created)
                }
                if form.importAfterCreate {
                    app.session(for: created.id).section = .importDocs
                    app.perform(.importDocuments)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// The sheet's editable state.
struct NewClassForm {
    var name = ""
    var courseCode = ""
    var termChoice: TermChoice = .named(AcademicTerms.suggestions().first ?? "")
    var customTerm = ""
    var tintId: String = ClassTintOption.accentId
    var tutorStyle: TutorStyle = .socratic
    var importAfterCreate = false

    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The term to store, or `nil` for "no term".
    var term: String? {
        switch termChoice {
        case .none: return nil
        case .named(let term): return term
        case .custom: return customTerm.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// The tint hex to store; `nil` keeps the scheme accent.
    func tintHex(for theme: ResolvedTheme) -> String? {
        ClassTintOption.options(for: theme).first { $0.id == tintId }?.hex
    }
}

enum TermChoice: Hashable {
    case none
    case named(String)
    case custom
}

// MARK: - Term picker

/// Current and upcoming terms, "No term", and "Custom…" which reveals a text field.
private struct TermPicker: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var choice: TermChoice
    @Binding var custom: String

    private let suggestions = AcademicTerms.suggestions()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Term", selection: $choice) {
                ForEach(suggestions, id: \.self) { term in
                    Text(term).tag(TermChoice.named(term))
                }
                Divider()
                Text("No term").tag(TermChoice.none)
                Text("Custom…").tag(TermChoice.custom)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(height: ThubanMetrics.buttonHeight)
            .accessibilityLabel("Term")
            if choice == .custom {
                TextField("Winter 2027", text: $custom)
                    .thubanField()
                    .accessibilityLabel("Custom term")
            }
        }
    }
}

// MARK: - Tab color row

/// Six color dots; the first is the scheme accent. The selected dot carries an accent ring.
private struct TintRow: View {
    @Environment(\.thubanTheme) private var theme
    var options: [ClassTintOption]
    @Binding var selectedId: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { option in
                let selected = option.id == selectedId
                Button {
                    selectedId = option.id
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: option.hex ?? theme.accent))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline))
                        if selected {
                            Glyph(.check, size: 12)
                                .foregroundStyle(Color(hex: ClassTintOption.inkOn(option.hex ?? theme.accent)))
                        }
                    }
                    .padding(3)
                    .overlay(
                        Circle().strokeBorder(selected ? theme.accentColor : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Text(options.first { $0.id == selectedId }?.label ?? "")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Rename

/// Rename from the tab's context menu.
struct RenameClassSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var studyClass: StudyClass
    @State private var name: String = ""

    var body: some View {
        ModalCard(title: "Rename class") {
            LabeledField("Name") {
                TextField("Class name", text: $name)
                    .thubanField()
                    .accessibilityLabel("Class name")
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Rename") {
                Task {
                    try? await app.renameClass(studyClass.id, to: name)
                    dismiss()
                }
            }
            .buttonStyle(.thubanPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { name = studyClass.name }
    }
}

// MARK: - Modal chrome

/// Design-brief modal: card with 1 px border, radius 14, 24 pt padding, serif title 20.
struct ModalCard<Content: View, Actions: View>: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    var width: CGFloat = 460
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(ThubanFont.display(20))
                .foregroundStyle(theme.inkColor)
            content()
            HStack(spacing: 10) {
                Spacer()
                actions()
            }
        }
        .padding(24)
        .frame(width: width)
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.modalRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.modalRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
        .foregroundStyle(theme.inkColor)
    }
}

/// Eyebrow label above a control.
struct LabeledField<Content: View>: View {
    @Environment(\.thubanTheme) private var theme
    var label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
