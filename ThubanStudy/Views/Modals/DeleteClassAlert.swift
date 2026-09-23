import SwiftUI
import ThubanCore

/// "Delete <class>?" — danger icon, what the class holds (fetched from the store), the "Also delete the n imported
/// files from disk" checkbox, then Cancel / Delete class.
struct DeleteClassAlert: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var studyClass: StudyClass

    @State private var counts: ClassContentCounts?
    @State private var countsError: String?
    @State private var deleteFiles = false
    @State private var error: String?
    @State private var isDeleting = false

    var body: some View {
        ModalCard(title: "Delete “\(studyClass.name)”?") {
            VStack(alignment: .leading, spacing: 14.z) {
                HStack(alignment: .top, spacing: 12.z) {
                    ZStack {
                        Circle().fill(theme.negSoftColor).frame(width: 36.z, height: 36.z)
                        DangerGlyph(size: 20)
                            .foregroundStyle(theme.negTextColor)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6.z) {
                        Text(bodyText)
                            .font(ThubanFont.body(14))
                            .foregroundStyle(theme.inkDimColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if counts != nil {
                            HStack(spacing: 8.z) {
                                Chip(pluralized(counts?.questions ?? 0, "question"), kind: .neutral, icon: .questionBank)
                                Chip(pluralized(counts?.documents ?? 0, "document"), kind: .neutral, icon: .importDocs)
                                Chip(pluralized(counts?.figures ?? 0, "figure"), kind: .neutral, icon: .figureClip)
                            }
                        } else if countsError == nil {
                            HStack(spacing: 8.z) {
                                ProgressView().controlSize(.small)
                                Text("Counting what this class holds…")
                                    .font(ThubanFont.small)
                                    .foregroundStyle(theme.inkDimColor)
                            }
                        }
                        if let countsError {
                            Text(countsError)
                                .font(ThubanFont.small)
                                .foregroundStyle(theme.negTextColor)
                        }
                    }
                }

                Toggle(fileCheckboxLabel, isOn: $deleteFiles)
                    .toggleStyle(.checkbox)
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkColor)
                    .tint(theme.accentColor)
                    .disabled((counts?.documents ?? 0) == 0)

                Text("Attempts, progress and the tutor transcript go with the class. This cannot be undone.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)

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
            // Deliberately no `.defaultAction`: Return must not delete a class (HIG — destructive actions are
            // never the default); Escape cancels, the button needs a click.
            Button(isDeleting ? "Deleting…" : "Delete class") { confirm() }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isDeleting)
        }
        .task(id: studyClass.id) { await loadCounts() }
    }

    // MARK: Text

    private var bodyText: String {
        var line = "Everything in this class will be removed"
        if let studyClassCode = studyClass.courseCode?.nilIfEmpty {
            line += " (\(studyClassCode))"
        }
        if let counts {
            if counts.isEmpty {
                return line + ". It holds no questions or documents yet."
            }
            let parts = [
                pluralized(counts.questions, "question"),
                pluralized(counts.documents, "imported document"),
                pluralized(counts.figures, "figure"),
            ]
            return line + ": " + parts.joined(separator: ", ") + "."
        }
        return line + "."
    }

    private var fileCheckboxLabel: String {
        let documents = counts?.documents ?? 0
        guard documents > 0 else { return "Also delete imported files from disk" }
        var label = "Also delete the \(pluralized(documents, "imported file")) from disk"
        if let bytes = counts?.documentBytes, bytes > 0 {
            label += " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
        }
        return label
    }

    private func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func loadCounts() async {
        do {
            counts = try await app.contentCounts(for: studyClass.id)
        } catch {
            countsError = error.localizedDescription
        }
    }

    private func confirm() {
        guard !isDeleting else { return }
        isDeleting = true
        error = nil
        Task {
            do {
                try await app.deleteClass(studyClass.id, deleteFiles: deleteFiles)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isDeleting = false
        }
    }
}

/// `neg` fill for destructive confirmations; text uses the theme's on-accent ink for fills.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.z, weight: .semibold))
            .foregroundStyle(Color(hex: (try? ColorMath.onAccent(theme.neg)) ?? ColorMath.darkOnAccent))
            .padding(.horizontal, 16.z)
            .frame(height: ThubanMetrics.buttonHeight)
            .background(
                theme.negColor.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
    }
}
