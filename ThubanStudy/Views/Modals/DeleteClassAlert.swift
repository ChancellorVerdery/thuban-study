import SwiftUI
import ThubanCore

/// "Delete <class>?" confirmation with the "Also delete imported files" checkbox.
struct DeleteClassAlert: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var studyClass: StudyClass
    @State private var deleteFiles = false
    @State private var error: String?
    @State private var isDeleting = false

    var body: some View {
        ModalCard(title: "Delete “\(studyClass.name)”?") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The question bank, attempts and tutor transcript for this class will be removed. This cannot be undone.")
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Also delete imported files", isOn: $deleteFiles)
                    .toggleStyle(.checkbox)
                    .font(ThubanFont.body(14))
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
            Button(isDeleting ? "Deleting…" : "Delete class") {
                isDeleting = true
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
            .buttonStyle(DestructiveButtonStyle())
            .disabled(isDeleting)
        }
    }
}

/// `neg` fill for destructive confirmations.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.thubanTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(hex: "#14100a"))
            .padding(.horizontal, 16)
            .frame(height: ThubanMetrics.buttonHeight)
            .background(theme.negColor.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
    }
}
