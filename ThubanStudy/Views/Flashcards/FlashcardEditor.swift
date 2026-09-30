import SwiftUI
import ThubanCore

/// Write or edit a card. Front and back are fields with inline, rendered math (the tutor composer in multi-line
/// mode: "$" starts a formula, "$" or → at its end leaves it); the preview below shows the card as it will be
/// reviewed, Markdown included.
struct FlashcardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.thubanTheme) private var theme
    var session: ClassSession
    @State var draft: FlashcardDraft
    @State private var front = ComposerWebView.Controller(name: "flashcard-front")
    @State private var back = ComposerWebView.Controller(name: "flashcard-back")
    @State private var preview = FlashcardDeckWebView.Controller(name: "flashcard-preview")
    @State private var isSaving = false
    @State private var error: String?

    init(session: ClassSession, draft: FlashcardDraft) {
        self.session = session
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool {
        !draft.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ModalCard(title: draft.cardId == nil ? "New card" : "Edit card", width: 640) {
            VStack(alignment: .leading, spacing: 14.z) {
                field("Front", controller: front)
                field("Back", controller: back)
                Text("Type $ for a formula ($$ for one on its own line); Enter starts a new line, ⌘⏎ saves. Markdown works too: **bold**, lists.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledField("Preview") {
                    FlashcardDeckWebView(controller: preview)
                        .frame(height: 150.z)
                        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                }
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
            Button(isSaving ? "Saving…" : "Save card", action: save)
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave || isSaving)
        }
        .onAppear(perform: wire)
    }

    private func field(_ label: String, controller: ComposerWebView.Controller) -> some View {
        LabeledField(label) {
            ComposerWebView(controller: controller)
                .frame(height: min(max(controller.contentHeight + 2, 74), 220).z)
                .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                        .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
                )
        }
    }

    private func wire() {
        front.configure(placeholder: "Question, term or prompt", label: "Card front", multiline: true)
        back.configure(placeholder: "Answer", label: "Card back", multiline: true)
        front.setInitialText(draft.front)
        back.setInitialText(draft.back)
        front.onInput = { text in draft.front = text; updatePreview() }
        back.onInput = { text in draft.back = text; updatePreview() }
        front.onSubmit = { _ in save() }
        back.onSubmit = { _ in save() }
        front.onReady = { front.focus() }
        updatePreview()
    }

    private func updatePreview() {
        preview.showPreview(front: draft.front, back: draft.back)
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            if await session.saveFlashcard(draft) {
                dismiss()
            } else {
                error = session.flashcards.error ?? "The card could not be saved."
                isSaving = false
            }
        }
    }
}
