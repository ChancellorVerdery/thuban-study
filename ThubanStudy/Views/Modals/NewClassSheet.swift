import SwiftUI
import ThubanCore

/// Create a class: name, course code, term, tutor style. (The screens phase may replace this with the design-board version.)
struct NewClassSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var courseCode = ""
    @State private var term = ""
    @State private var tutorStyle: TutorStyle = .socratic
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        ModalCard(title: "New class") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("Name") {
                    TextField("Multivariable Calculus", text: $name)
                }
                HStack(spacing: 12) {
                    LabeledField("Course code") {
                        TextField("MATH 2210", text: $courseCode)
                    }
                    LabeledField("Term") {
                        TextField("Fall 2026", text: $term)
                    }
                }
                LabeledField("Tutor style") {
                    Picker("Tutor style", selection: $tutorStyle) {
                        ForEach(TutorStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Text(tutorStyle.summary)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                if let error {
                    Text(error)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.negTextColor)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button(isSaving ? "Creating…" : "Create class") { save() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await app.createClass(name: name, courseCode: courseCode, term: term, tutorStyle: tutorStyle)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

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
                    .textFieldStyle(.roundedBorder)
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
