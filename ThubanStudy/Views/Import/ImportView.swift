import AppKit
import SwiftUI
import ThubanCore
import UniformTypeIdentifiers

/// Import documents: drop zone + file chooser, the current batch with per-file status, the right rail
/// (agent policy, figures explainer, question-type counts) and the progress sheet while a run is active.
struct ImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession
    /// Set to open the figure review for one document's figures.
    @State private var reviewingDocument: ImportedDocument?

    var body: some View {
        @Bindable var pipeline = session.importPipeline
        Group {
            if let document = reviewingDocument {
                FigureReviewView(session: session, scope: .document(document), onClose: { reviewingDocument = nil })
            } else {
                content(pipeline: pipeline)
            }
        }
        .task(id: session.classId) { await session.loadDocuments() }
        .onChange(of: app.importPanelRequest, initial: true) { _, request in
            // ⌘I switches to this section and bumps the counter in the same turn, so the view may mount after
            // the change: compare against the last request this app run has handled instead.
            guard ImportFilePanel.consume(request) else { return }
            reviewingDocument = nil
            ImportFilePanel.present(for: session)
        }
        .sheet(isPresented: $pipeline.isSheetPresented) {
            ImportProgressSheet(session: session)
                .environment(\.thubanTheme, theme)
        }
    }

    private func content(pipeline: ImportPipeline) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    ImportDropZone(session: session)
                    ImportBatchCard(session: session, onReviewFigures: { reviewingDocument = $0 })
                    if let error = pipeline.lastError ?? session.lastError {
                        Text(error)
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.negTextColor)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ImportRail(session: session)
                .frame(width: 320)
                .thubanHairline(.leading, color: theme.lineColor)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import documents")
                .font(ThubanFont.display(28))
                .foregroundStyle(theme.inkColor)
            Text("Add course material to \(session.studyClass?.name ?? "this class"). The import agent reads each file and adds its questions to the bank.")
                .font(ThubanFont.body(15))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - File panel

/// The NSOpenPanel for "Choose files…" and ⌘I.
enum ImportFilePanel {
    /// The last `AppModel.importPanelRequest` value that opened a panel.
    @MainActor private static var handledRequest = 0

    /// True (once) for a request newer than the last one handled.
    @MainActor
    static func consume(_ request: Int) -> Bool {
        guard request > handledRequest else { return false }
        handledRequest = request
        return true
    }

    @MainActor
    static func present(for session: ClassSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = DocumentParserRegistry.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose documents to import into \(session.studyClass?.name ?? "this class")"
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await session.enqueue(urls: urls) }
        }
    }
}

// MARK: - Drop zone

/// Large dashed drop target; accepts file URLs with a supported extension.
struct ImportDropZone: View {
    @Environment(\.thubanTheme) private var theme
    var session: ClassSession
    @State private var isTargeted = false
    @State private var rejected: Int = 0

    private static let supported = Set(DocumentParserRegistry.supportedExtensions)

    var body: some View {
        VStack(spacing: 10) {
            Icon(.importDocs, size: 30)
                .foregroundStyle(theme.brassInkColor)
            Text("Drop documents here")
                .font(ThubanFont.display(22))
                .foregroundStyle(theme.inkColor)
            Text("PDF, Word, Excel, CSV, HTML, MHTML, PowerPoint, Markdown, text and images")
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
            HStack(spacing: 10) {
                Button("Choose files…") { ImportFilePanel.present(for: session) }
                    .buttonStyle(.thubanSecondary)
                Text("or press ⌘I")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }
            .padding(.top, 6)
            if rejected > 0 {
                Text("\(rejected) file\(rejected == 1 ? " was" : "s were") skipped: unsupported type.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.negTextColor)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .padding(24)
        .background(isTargeted ? theme.accentTintColor : theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(isTargeted ? theme.accentColor : theme.line2Color, style: StrokeStyle(lineWidth: ThubanMetrics.hairline, dash: [6, 4]))
        )
        .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            let accepted = files.filter { Self.supported.contains($0.pathExtension.lowercased()) }
            rejected = files.count - accepted.count
            guard !accepted.isEmpty else { return false }
            Task { await session.enqueue(urls: accepted) }
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop documents here")
    }
}

// MARK: - Batch card

/// "This import — n files": the queued files and the ones of the current run, then earlier imports.
struct ImportBatchCard: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(AppModel.self) private var app
    var session: ClassSession
    var onReviewFigures: (ImportedDocument) -> Void
    @State private var confirmingCancel = false
    /// The finished document the student asked to remove, with what would go with it.
    @State private var pendingRemoval: PendingRemoval?

    private var pipeline: ImportPipeline { session.importPipeline }

    struct PendingRemoval: Identifiable {
        var document: ImportedDocument
        var footprint: DocumentFootprint
        var id: DocumentID { document.id }
    }

    private var batch: [ImportedDocument] {
        let ids = pipeline.batchIds
        return session.importQueue.filter { $0.status == .queued || ids.contains($0.id) || !$0.status.isTerminal }
    }

    private var earlier: [ImportedDocument] {
        let batchIds = Set(batch.map(\.id))
        return session.importQueue.filter { !batchIds.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(title: "This import", count: batch.count, documents: batch, empty: "No files yet. Drop documents above or choose them from disk.")
            footer
            if !earlier.isEmpty {
                section(title: "Imported earlier", count: earlier.count, documents: earlier, empty: nil)
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove “\($0.document.filename)”?" } ?? "Remove file?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { removal in
            let f = removal.footprint
            if f.questionCount > 0 || f.figureCount > 0 {
                Button("Remove file, \(Self.count(f.questionCount, "question")) and \(Self.count(f.figureCount, "figure"))", role: .destructive) {
                    Task { await session.removeDocument(removal.document.id) }
                }
                Button(f.questionCount > 0 ? "Remove file only, keep the \(Self.count(f.questionCount, "question"))" : "Remove file only") {
                    Task { await session.removeDocument(removal.document.id, keepQuestions: true) }
                }
            } else {
                Button("Remove file", role: .destructive) {
                    Task { await session.removeDocument(removal.document.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            let f = removal.footprint
            if f.questionCount > 0 {
                Text("This file produced \(Self.count(f.questionCount, "question")) and \(Self.count(f.figureCount, "figure")). "
                     + "Keeping the questions also keeps the \(Self.count(f.referencedFigureCount, "figure")) they use; the stored copy of the file is deleted either way.")
            } else {
                Text("The stored copy of the file\(f.figureCount > 0 ? " and its \(Self.count(f.figureCount, "figure"))" : "") will be deleted.")
            }
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func askToRemove(_ document: ImportedDocument) {
        Task {
            let footprint = await session.footprint(of: document.id)
            pendingRemoval = PendingRemoval(document: document, footprint: footprint)
        }
    }

    private func section(title: String, count: Int, documents: [ImportedDocument], empty: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(ThubanFont.display(18))
                    .foregroundStyle(theme.inkColor)
                Text("— \(count) file\(count == 1 ? "" : "s")")
                    .font(ThubanFont.body(15))
                    .foregroundStyle(theme.inkDimColor)
            }
            if documents.isEmpty, let empty {
                Text(empty)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .thubanPanel(padding: 0)
            } else if !documents.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                        ImportDocumentRow(document: document, activity: pipeline.activity(for: document.id), onRemove: {
                            if document.status == .done {
                                askToRemove(document)
                            } else {
                                Task { await session.removeDocument(document.id) }
                            }
                        }, onRetry: {
                            Task { await session.retryDocument(document.id) }
                        }, onReviewFigures: { onReviewFigures(document) })
                        if index < documents.count - 1 {
                            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                        }
                    }
                }
                .thubanPanel(padding: 0)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            let queued = session.queuedDocuments.count
            Button {
                session.startImport()
            } label: {
                Text(queued > 0 ? "Add to \(session.studyClass?.name ?? "class") (\(queued))" : "Add to \(session.studyClass?.name ?? "class")")
            }
            .buttonStyle(.thubanPrimary)
            .disabled(queued == 0 || pipeline.isRunning || !app.isConnected)
            .keyboardShortcut(.defaultAction)
            .help(app.isConnected ? "Start the import for the queued files" : "Connect your Claude account in Settings first")
            if pipeline.isRunning {
                Button("Cancel") { confirmingCancel = true }
                    .buttonStyle(.thubanSecondary)
                    .keyboardShortcut(".", modifiers: .command)
                Button("Show progress") { pipeline.isSheetPresented = true }
                    .buttonStyle(.thubanGhostTinted)
            }
            Spacer()
            Text(app.isConnected ? "Questions are added to the bank as each file finishes." : "Connect your Claude account in Settings to run the import agent.")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
                .multilineTextAlignment(.trailing)
        }
        .confirmationDialog("Cancel the import?", isPresented: $confirmingCancel) {
            Button("Cancel import", role: .destructive) { pipeline.cancel() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Files already finished keep their questions. The current file goes back to the queue.")
        }
    }
}

// MARK: - Document row

/// kind badge · name · size · status line + progress · result chip.
struct ImportDocumentRow: View {
    @Environment(\.thubanTheme) private var theme
    var document: ImportedDocument
    var activity: ImportPipeline.FileActivity?
    var onRemove: () -> Void
    var onRetry: () -> Void = {}
    var onReviewFigures: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            KindBadge(kind: document.kind)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(document.filename)
                        .font(ThubanFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.inkColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                }
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(ThubanFont.small)
                        .foregroundStyle(document.status == .failed ? theme.negTextColor : theme.inkDimColor)
                        .lineLimit(1)
                    WarningsChip(warnings: warnings, filename: document.filename)
                    if let model = document.modelUsed.flatMap(ClaudeModel.init(modelId:)), document.status != .queued {
                        Chip(model.shortName, kind: model == .opus ? .warn : .neutral)
                    }
                }
                if isActive {
                    ProgressBar(value: progressValue, height: 4)
                        .frame(maxWidth: 280)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var isActive: Bool {
        !(document.status == .queued || document.status.isTerminal)
    }

    /// A row with an in-flight status but no live activity was left behind by an earlier run.
    private var isOrphaned: Bool {
        isActive && (activity == nil || activity?.isFinished == true)
    }

    private var warnings: [String] {
        document.status == .done ? document.warnings : []
    }

    private var statusText: String {
        switch document.status {
        case .queued:
            switch document.statusDetail {
            case "Cancelled": return "Queued · cancelled last time"
            case "Interrupted": return "Queued · interrupted last time"
            case "Retry": return "Queued · retry"
            default: return "Queued"
            }
        case .failed: return document.statusDetail ?? "Failed"
        case .done: return document.classification.map(Self.label(for:)) ?? "Done"
        default: return document.statusDetail ?? document.status.rawValue
        }
    }

    private static func label(for classification: DocumentClassification) -> String {
        switch classification {
        case .existingQuestions: return "Existing questions extracted"
        case .readingMaterial: return "Questions generated from the reading"
        case .mixed: return "Questions extracted and generated"
        }
    }

    private var progressValue: Double {
        switch activity?.phase {
        case .reading: return 0.15
        case .figures: return 0.3
        case .generating, .escalated: return 0.6
        case .analysingFigures: return 0.85
        case .done: return 1
        default:
            switch document.status {
            case .reading: return 0.15
            case .extractingFigures: return 0.3
            case .generating, .escalated: return 0.6
            default: return 0.05
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch document.status {
        case .queued:
            IconButton(glyph: .close, label: "Remove \(document.filename) from the queue", size: 28, iconSize: 14, action: onRemove)
        case .done:
            HStack(spacing: 8) {
                if document.figureCount > 0 {
                    Button("Review figures (\(document.figureCount))") { onReviewFigures() }
                        .buttonStyle(GhostButtonStyle(height: 28, tinted: true))
                }
                Chip("Done · \(document.questionCount) question\(document.questionCount == 1 ? "" : "s")", kind: .pos)
                IconButton(glyph: .close, label: "Remove \(document.filename)", size: 28, iconSize: 14, action: onRemove)
                    .help("Remove this file; you choose whether its questions and figures go too")
            }
        case .failed:
            HStack(spacing: 8) {
                Chip("Failed", kind: .neg)
                Button("Retry") { onRetry() }
                    .buttonStyle(GhostButtonStyle(height: 28, tinted: true))
                    .help("Put \(document.filename) back in the queue; the stored copy is reused")
                IconButton(glyph: .close, label: "Remove \(document.filename)", size: 28, iconSize: 14, action: onRemove)
            }
        case .escalated:
            HStack(spacing: 8) {
                Chip("Escalated to Opus", kind: .warn)
                if isOrphaned {
                    IconButton(glyph: .close, label: "Remove \(document.filename)", size: 28, iconSize: 14, action: onRemove)
                }
            }
        case .reading, .extractingFigures, .generating:
            HStack(spacing: 8) {
                Chip(phaseLabel, kind: .signal)
                if isOrphaned {
                    IconButton(glyph: .close, label: "Remove \(document.filename)", size: 28, iconSize: 14, action: onRemove)
                }
            }
        }
    }

    private var phaseLabel: String {
        switch document.status {
        case .reading: return "Reading"
        case .extractingFigures: return "Figures"
        default: return "Generating"
        }
    }
}

/// A 3–4 letter uppercase mono badge for the document kind.
struct KindBadge: View {
    @Environment(\.thubanTheme) private var theme
    var kind: DocumentKind

    var body: some View {
        Text(label)
            .font(ThubanFont.mono(10, weight: .medium))
            .foregroundStyle(theme.inkDimColor)
            .frame(width: 44, height: 24)
            .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous).strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline))
            .accessibilityLabel(kind.rawValue)
    }

    private var label: String {
        switch kind {
        case .markdown: return "MD"
        case .text: return "TXT"
        case .image: return "IMG"
        case .other: return "FILE"
        default: return kind.rawValue.uppercased()
        }
    }
}

// MARK: - Right rail

struct ImportRail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var session: ClassSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                agentCard
                figuresCard
                typesCard
            }
            .padding(20)
        }
        .background(theme.bgColor)
    }

    private var agentCard: some View {
        RailCard(title: "Import agent") {
            VStack(alignment: .leading, spacing: 10) {
                PolicyRow(label: "Default", value: app.importModels.defaultModel.shortName)
                PolicyRow(label: "Escalation", value: app.importModels.escalation.map { "\($0.shortName) when needed" } ?? "Off")
                HStack(spacing: 8) {
                    Text("Account")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .frame(width: 84, alignment: .leading)
                    Chip(app.connectionSummary, kind: app.isConnected ? .pos : (app.connection.needsAttention ? .warn : .neutral), dot: true)
                }
                Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                Toggle(isOn: Binding(get: { app.modelPolicy.allowEscalation }, set: { app.setAllowEscalation($0) })) {
                    Text("The agent may escalate to Opus")
                        .font(ThubanFont.body(14))
                        .foregroundStyle(theme.inkColor)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text("Sonnet by default. The agent may escalate itself to Opus for dense material (proofs, multivariable calculus, organic mechanisms).")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var figuresCard: some View {
        RailCard(title: "Figures") {
            VStack(alignment: .leading, spacing: 10) {
                FigureBeforeAfter()
                    .frame(height: 84)
                Text("Charts clipped from your documents are redrawn in the app's own graph style. Review each one in the bank under Figures; diagrams and photos stay as they are.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var typesCard: some View {
        let counts = session.importPipeline.typeCounts
        let total = counts.values.reduce(0, +)
        let ordered = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .sorted { !$0.key.isEmpty && $1.key.isEmpty }
        return RailCard(title: "Question types") {
            VStack(alignment: .leading, spacing: 8) {
                if total == 0 {
                    Text(session.importPipeline.isRunning ? "Counting as files finish…" : "Nothing imported in this session yet.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                } else {
                    ForEach(ordered, id: \.key) { entry in
                        HStack {
                            Text(entry.key.isEmpty ? Question.unclassifiedLabel : entry.key)
                                .font(ThubanFont.small)
                                .foregroundStyle(entry.key.isEmpty ? theme.inkDimColor : theme.inkColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("\(entry.value)")
                                .font(ThubanFont.mono(13))
                                .foregroundStyle(theme.inkColor)
                        }
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    HStack {
                        Text("Total")
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.inkDimColor)
                        Spacer()
                        Text("\(total)")
                            .font(ThubanFont.mono(13))
                            .foregroundStyle(theme.inkColor)
                    }
                }
            }
        }
    }
}

/// A rail card: eyebrow title + content in a panel.
struct RailCard<Content: View>: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .thubanPanel(padding: 16)
    }
}

private struct PolicyRow: View {
    @Environment(\.thubanTheme) private var theme
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(ThubanFont.body(14, weight: .semibold))
                .foregroundStyle(theme.inkColor)
        }
    }
}

/// Tiny before/after: a crude hand-drawn-looking curve on the left, the clean brass curve with axes on the right.
struct FigureBeforeAfter: View {
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            panel(label: "Original") { rect in
                var path = Path()
                let points: [CGPoint] = [(0.08, 0.82), (0.2, 0.7), (0.31, 0.74), (0.45, 0.5), (0.55, 0.56), (0.7, 0.3), (0.82, 0.36), (0.92, 0.18)]
                    .map { CGPoint(x: rect.minX + $0.0 * rect.width, y: rect.minY + $0.1 * rect.height) }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                var axes = Path()
                axes.move(to: CGPoint(x: rect.minX + 0.06 * rect.width, y: rect.minY + 0.1 * rect.height))
                axes.addLine(to: CGPoint(x: rect.minX + 0.05 * rect.width, y: rect.maxY - 0.08 * rect.height))
                axes.addLine(to: CGPoint(x: rect.maxX - 0.04 * rect.width, y: rect.maxY - 0.1 * rect.height))
                return [(axes, theme.inkFaintColor, 1.2), (path, theme.inkDimColor, 1.6)]
            }
            Glyph(.chevronRight, size: 14)
                .foregroundStyle(theme.inkFaintColor)
            panel(label: "Standardized") { rect in
                var grid = Path()
                for i in 1..<4 {
                    let x = rect.minX + rect.width * CGFloat(i) / 4
                    let y = rect.minY + rect.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                    grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                var axes = Path()
                axes.move(to: CGPoint(x: rect.minX + 0.08 * rect.width, y: rect.minY))
                axes.addLine(to: CGPoint(x: rect.minX + 0.08 * rect.width, y: rect.maxY))
                axes.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.1 * rect.height))
                axes.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.1 * rect.height))
                var curve = Path()
                curve.move(to: CGPoint(x: rect.minX + 0.08 * rect.width, y: rect.maxY - 0.15 * rect.height))
                curve.addCurve(to: CGPoint(x: rect.maxX - 0.05 * rect.width, y: rect.minY + 0.15 * rect.height),
                               control1: CGPoint(x: rect.minX + 0.5 * rect.width, y: rect.maxY - 0.1 * rect.height),
                               control2: CGPoint(x: rect.minX + 0.6 * rect.width, y: rect.minY + 0.1 * rect.height))
                return [(grid, theme.lineColor, 1), (axes, theme.line2Color, 1), (curve, theme.accentColor, 2)]
            }
        }
    }

    private func panel(label: String, _ paths: @escaping (CGRect) -> [(Path, Color, CGFloat)]) -> some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
                for (path, color, width) in paths(rect) {
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                }
            }
            .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.inkDimColor)
        }
        .accessibilityHidden(true)
    }
}
