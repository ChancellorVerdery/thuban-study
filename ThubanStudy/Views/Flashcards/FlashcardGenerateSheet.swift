import AppKit
import SwiftUI
import ThubanCore
import UniformTypeIdentifiers

/// Generate cards: choose material (pasted notes, this class's imported documents, other files), let the agent
/// write cards with rendered math, then keep the ones you want.
struct FlashcardGenerateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.thubanTheme) private var theme
    var session: ClassSession

    enum Phase: Equatable { case choosing, working(String), picking, failed(String) }

    @State private var notes = ""
    @State private var chosenDocuments: Set<DocumentID> = []
    @State private var files: [URL] = []
    @State private var target = 20
    @State private var phase: Phase = .choosing
    @State private var cards: [(front: String, back: String, on: Bool)] = []
    @State private var pickPage = FlashcardDeckWebView.Controller(name: "flashcard-pick")
    @State private var task: Task<Void, Never>?

    /// Every stored document, imported or not: a queued textbook is still good material for cards.
    private var documents: [ImportedDocument] { session.importQueue }
    private var hasMaterial: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chosenDocuments.isEmpty || !files.isEmpty
    }
    private var keptCount: Int { cards.filter(\.on).count }

    var body: some View {
        ModalCard(title: "Generate flashcards", width: 720) {
            switch phase {
            case .choosing, .failed:
                chooser
            case .working(let step):
                HStack(spacing: 12.z) {
                    ProgressView().controlSize(.small)
                    Text(step)
                        .font(ThubanFont.body(14))
                        .foregroundStyle(theme.inkDimColor)
                }
                .frame(maxWidth: .infinity, minHeight: 160.z)
            case .picking:
                VStack(alignment: .leading, spacing: 8.z) {
                    Text("\(keptCount) of \(cards.count) cards kept. Untick any you don't want; you can edit the rest later in the card bank.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                    FlashcardDeckWebView(controller: pickPage)
                        .frame(height: 380.z)
                        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                }
            }
        } actions: {
            Button("Cancel") {
                task?.cancel()
                dismiss()
            }
            .buttonStyle(.thubanSecondary)
            .keyboardShortcut(.cancelAction)
            switch phase {
            case .picking:
                Button("Add \(keptCount) card\(keptCount == 1 ? "" : "s")") { add() }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(keptCount == 0)
            case .working:
                EmptyView()
            default:
                Button("Generate") { generate() }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasMaterial)
            }
        }
        .task {
            if session.importQueue.isEmpty { await session.loadDocuments() }
            pickPage.onToggle = { index, on in
                if cards.indices.contains(index) { cards[index].on = on }
            }
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14.z) {
            LabeledField("Notes") {
                TextEditor(text: $notes)
                    .font(ThubanFont.body(14))
                    .scrollContentBackground(.hidden)
                    .padding(8.z)
                    .frame(height: 120.z)
                    .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Paste lecture notes, a summary, a formula list…")
                                .font(ThubanFont.body(14))
                                .foregroundStyle(theme.inkFaintColor)
                                .padding(.horizontal, 13.z)
                                .padding(.vertical, 8.z)
                                .allowsHitTesting(false)
                        }
                    }
            }
            if !documents.isEmpty {
                LabeledField("This class's documents") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6.z) {
                            ForEach(documents) { document in
                                Toggle(isOn: Binding(
                                    get: { chosenDocuments.contains(document.id) },
                                    set: { on in if on { chosenDocuments.insert(document.id) } else { chosenDocuments.remove(document.id) } }
                                )) {
                                    Text(document.filename)
                                        .font(ThubanFont.body(13))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120.z)
                }
            }
            LabeledField("Other files") {
                HStack(spacing: 10.z) {
                    Button("Add files…") { pickFiles() }
                        .buttonStyle(.thubanSecondary)
                    Text(files.isEmpty ? "PDF, Word, PowerPoint, images, text" : files.map(\.lastPathComponent).joined(separator: ", "))
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 10.z) {
                Text("About")
                    .font(ThubanFont.body(14))
                Picker("Cards", selection: $target) {
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0) cards").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            if case .failed(let message) = phase {
                Text(message)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.negTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentParserRegistry.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        files.append(contentsOf: panel.urls.filter { !files.contains($0) })
    }

    // MARK: Generating

    private func generate() {
        guard hasMaterial else { return }
        let session = session
        let notes = notes
        let documents = documents.filter { chosenDocuments.contains($0.id) }
        let files = files
        let target = target
        phase = .working("Reading the material…")
        task = Task {
            do {
                var material: [FlashcardGenerator.Material] = []
                if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    material.append(.init(title: "Pasted notes", text: notes))
                }
                var urls: [(String, URL)] = documents.compactMap { doc in session.store.documentURL(doc.storedPath).map { (doc.filename, $0) } }
                urls += files.map { ($0.lastPathComponent, $0) }
                for (title, url) in urls {
                    let content = try await DocumentParserRegistry.parse(url: url)
                    let pages = content.pageImages.keys.sorted().prefix(4).compactMap { content.pageImages[$0] }
                    let pictures = pages.isEmpty ? content.figures.prefix(2).map(\.pngData) : Array(pages)
                    material.append(.init(title: title, text: content.fullText, images: pictures))
                }
                try Task.checkCancellation()
                phase = .working("Writing cards…")
                let made = try await FlashcardGenerator(client: session.app.claudeClient).generate(
                    from: material,
                    classContext: session.app.classContext(for: session.classId),
                    existingFronts: session.flashcards.cards.map(\.front),
                    target: target
                )
                try Task.checkCancellation()
                guard !made.isEmpty else {
                    phase = .failed("No cards came out of that material. Try adding more of it.")
                    return
                }
                cards = made.map { ($0.front, $0.back, true) }
                pickPage.showPick(cards)
                phase = .picking
            } catch is CancellationError {
                return
            } catch {
                phase = .failed("Couldn't generate cards: \(error.localizedDescription)")
            }
        }
    }

    private func add() {
        let kept = cards.filter(\.on).map { (front: $0.front, back: $0.back) }
        Task {
            await session.addFlashcards(kept)
            session.flashcards.mode = .bank
            dismiss()
        }
    }
}
