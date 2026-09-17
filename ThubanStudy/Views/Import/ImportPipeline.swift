import Foundation
import Observation
import ThubanCore
import os

/// Runs the import for one class: parse → figures → import agent → questions → figure agent, one file at a time.
/// One pipeline exists per class (`ImportPipeline.pipeline(for:)`); it survives view rebuilds so a run can continue
/// in the background while the student moves to another section.
@MainActor
@Observable
final class ImportPipeline {
    private static let logger = Logger(subsystem: "com.thuban.study", category: "import")
    /// Figures analysed per document; the rest stay `.pending` and can be reviewed as originals.
    static let maxAnalysedFigures = 24

    /// Per-file progress shown in the activity list.
    struct FileActivity: Identifiable, Equatable {
        enum Phase: Equatable { case waiting, reading, figures, generating, escalated, analysingFigures, done, failed, cancelled }
        var id: DocumentID
        var filename: String
        var phase: Phase = .waiting
        var detail: String = "Waiting"
        var model: ClaudeModel?
        /// The chunk being generated (0-based) and the chunk count, once the agent reports them.
        var chunkIndex: Int?
        var chunkCount: Int?
        var questionCount = 0
        var figureCount = 0
        var chartCount = 0
        var warnings: [String] = []
        var error: String?

        var isFinished: Bool { phase == .done || phase == .failed || phase == .cancelled }

        /// "Generating questions · part 3 of 12 · Opus": phase, chunk and model composed, so no event wipes another's information.
        var generatingDetail: String {
            var text = "Generating questions"
            if let chunkIndex, let chunkCount, chunkCount > 1 { text += " · part \(chunkIndex + 1) of \(chunkCount)" }
            if let model { text += " · \(model.shortName)" }
            return text
        }
    }

    /// The agent asked for Opus on a file; the sheet offers to keep it or pin Sonnet for the rest of the run.
    struct EscalationNotice: Equatable {
        var documentId: DocumentID
        var filename: String
        var reason: String
    }

    // MARK: Registry

    @ObservationIgnored private static var registry: [ClassID: ImportPipeline] = [:]

    static func pipeline(for session: ClassSession) -> ImportPipeline {
        if let existing = registry[session.classId] { return existing }
        let pipeline = ImportPipeline(session: session)
        registry[session.classId] = pipeline
        return pipeline
    }

    // MARK: State

    let classId: ClassID
    @ObservationIgnored private let session: ClassSession
    @ObservationIgnored private var runTask: Task<Void, Never>?

    private(set) var isRunning = false
    /// Documents of the current (or last) run, in order.
    private(set) var activities: [FileActivity] = []
    private(set) var escalationNotice: EscalationNotice?
    /// Reasons already acknowledged (so the notice is not shown twice for one run).
    private var acknowledgedEscalations: Set<DocumentID> = []
    /// The policy for this run; "Use Sonnet anyway" pins Sonnet here for the remaining files.
    private(set) var runPolicy: ModelPolicy = .default
    /// Questions produced so far in this run, by agent-classified type ("" = unclassified).
    private(set) var typeCounts: [String: Int] = [:]
    /// Set while a run is active and the progress sheet has not been dismissed to the background.
    var isSheetPresented = false
    /// A run-level error (nothing to import, not connected).
    var lastError: String?

    private init(session: ClassSession) {
        self.classId = session.classId
        self.session = session
    }

    // MARK: Derived

    var batchIds: Set<DocumentID> { Set(activities.map(\.id)) }
    var finishedCount: Int { activities.filter(\.isFinished).count }
    var totalCount: Int { activities.count }
    var questionsSoFar: Int { activities.reduce(0) { $0 + $1.questionCount } }
    var fractionFinished: Double { totalCount == 0 ? 0 : Double(finishedCount) / Double(totalCount) }
    var summaryLine: String {
        "\(finishedCount) of \(totalCount) finished · \(questionsSoFar) question\(questionsSoFar == 1 ? "" : "s") so far"
    }

    func activity(for id: DocumentID) -> FileActivity? {
        activities.first { $0.id == id }
    }

    // MARK: Control

    /// Starts a run over the given queued documents. No-op while a run is active.
    func start(documents: [ImportedDocument], policy: ModelPolicy) {
        guard !isRunning else { return }
        let queued = documents.filter { $0.status == .queued }
        guard !queued.isEmpty else {
            lastError = "Nothing to import: add files first."
            return
        }
        lastError = nil
        isRunning = true
        isSheetPresented = true
        escalationNotice = nil
        acknowledgedEscalations = []
        runPolicy = policy
        typeCounts = [:]
        activities = queued.map { FileActivity(id: $0.id, filename: $0.filename) }
        runTask = Task { [weak self] in
            guard let self else { return }
            for document in queued {
                if Task.isCancelled { self.markCancelled(document.id); continue }
                await self.process(document)
            }
            self.isRunning = false
            self.runTask = nil
        }
    }

    /// Cancels the running import; the current file is reset to queued.
    func cancel() {
        runTask?.cancel()
    }

    /// "Keep Opus": dismisses the notice; the run keeps the policy as it is.
    func keepEscalation() {
        if let notice = escalationNotice { acknowledgedEscalations.insert(notice.documentId) }
        escalationNotice = nil
    }

    /// "Use Sonnet anyway": pins Sonnet for the rest of this run (the file already escalated finishes on Opus).
    func pinSonnetForRun() {
        if let notice = escalationNotice { acknowledgedEscalations.insert(notice.documentId) }
        runPolicy.pinned = .sonnet
        escalationNotice = nil
    }

    // MARK: Per document

    private func process(_ original: ImportedDocument) async {
        var document = original
        let store = session.store
        let app = session.app
        do {
            // 1. Read
            try Task.checkCancellation()
            document = await setStatus(document, .reading, detail: "Reading \(document.filename)", model: nil)
            update(document.id) { $0.phase = .reading; $0.detail = "Reading" }
            let fileURL = AppPaths.documentURL(document.storedPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ThubanError.parse("The stored file is missing: \(document.storedPath)")
            }
            let content = try await DocumentParserRegistry.parse(url: fileURL)

            // 2. Figures
            try Task.checkCancellation()
            let rejected = content.rejectedImageCount
            let figureLabel = "Extracting figures (\(content.figures.count)" + (rejected > 0 ? ", \(rejected) non-figure image\(rejected == 1 ? "" : "s") left out)" : ")")
            document = await setStatus(document, .extractingFigures, detail: figureLabel, model: nil)
            update(document.id) { $0.phase = .figures; $0.detail = figureLabel; $0.figureCount = content.figures.count }
            let figureIds = try await storeFigures(content.figures, documentId: document.id)

            // 3. Import agent
            try Task.checkCancellation()
            let policy = runPolicy
            let model = policy.effectiveModel
            document = await setStatus(document, .generating, detail: "Generating questions (\(model.shortName))", model: model.rawValue)
            update(document.id) { $0.phase = .generating; $0.detail = "Generating questions"; $0.model = model }
            let agent = ImportAgent(client: app.claudeClient, validator: { [engine = app.engine] template in
                await engine.validate(template)
            })
            let documentId = document.id
            // Progress events go through one stream so they are handled in the order the agent emitted them, and
            // are fully drained before the final status is written.
            let (events, continuation) = AsyncStream<ImportProgress>.makeStream()
            let relay = Task { @MainActor [weak self] in
                for await progress in events { self?.handle(progress, for: documentId) }
            }
            let outcome: Result<ImportResult, Error>
            do {
                let existingTypes = (try? await store.questionTypes(in: classId))?.map(\.type) ?? []
                outcome = .success(try await agent.run(
                    document: document,
                    content: content,
                    classContext: app.classContext(for: classId),
                    existingTypes: existingTypes,
                    policy: policy,
                    questionsPerChunk: app.questionBankSettings.defaults.questionsPerChunk
                ) { progress in continuation.yield(progress) })
            } catch {
                outcome = .failure(error)
            }
            continuation.finish()
            await relay.value
            let result = try outcome.get()

            // 4. Store questions
            try Task.checkCancellation()
            var questions = result.questions
            var warnings = result.warnings
            if let note = content.rejectedImagesNote { warnings.append(note) }
            for index in questions.indices {
                let indices = result.figureIndicesByQuestion[questions[index].id] ?? []
                questions[index].figureIds = indices.compactMap { figureIds[$0] }
                questions[index].documentId = document.id
                questions[index].classId = classId
            }
            try await store.insert(questions)
            for question in questions { typeCounts[question.type, default: 0] += 1 }
            update(document.id) { $0.questionCount = questions.count; $0.model = result.modelUsed }
            document.modelUsed = result.modelUsed.rawValue
            document.classification = result.classification
            document.questionCount = questions.count
            document.figureCount = content.figures.count
            document.warnings = warnings
            try await store.update(classification: result.classification, questionCount: questions.count,
                                   figureCount: content.figures.count, warnings: warnings, for: document.id)
            update(document.id) { $0.warnings = warnings }
            await session.loadQuestions()

            // 5. Figure agent (may reject images the size gate let through; those leave the bank again)
            let (charts, dropped) = await analyseFigures(content.figures, figureIds: figureIds, document: &document)
            if dropped > 0 {
                let remaining = max(0, content.figures.count - dropped)
                document.figureCount = remaining
                try await store.update(classification: result.classification, questionCount: questions.count,
                                       figureCount: remaining, warnings: warnings, for: document.id)
                update(document.id) { $0.figureCount = remaining }
                session.updateDocument(document)
                await session.loadQuestions()
            }

            // 6. Done
            let doneDetail = "Done · \(questions.count) question\(questions.count == 1 ? "" : "s")"
                + (charts > 0 ? " · \(charts) chart\(charts == 1 ? "" : "s")" : "")
                + (warnings.isEmpty ? "" : " · \(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
            update(document.id) { $0.phase = .done; $0.detail = doneDetail; $0.chartCount = charts }
            document = await setStatus(document, .done, detail: doneDetail, model: document.modelUsed)
            if !warnings.isEmpty {
                Self.logger.notice("Import warnings for \(document.filename, privacy: .public): \(warnings.joined(separator: " | "), privacy: .public)")
            }
        } catch is CancellationError {
            await resetToQueued(document)
        } catch let error as ThubanError where error == .cancelled {
            await resetToQueued(document)
        } catch {
            let message = error.localizedDescription
            Self.logger.error("Import failed for \(document.filename, privacy: .public): \(message, privacy: .public)")
            if let thuban = error as? ThubanError, thuban.isCredentialProblem {
                await session.app.noteCredentialProblem(thuban)
            }
            // The model that actually ran (an escalation updates the activity, not the local copy).
            let model = activity(for: document.id)?.model?.rawValue ?? document.modelUsed
            update(document.id) { $0.phase = .failed; $0.detail = "Failed"; $0.error = message }
            document = await setStatus(document, .failed, detail: message, model: model)
        }
    }

    private func handle(_ progress: ImportProgress, for id: DocumentID) {
        // Nothing may touch a file after its final status is set (late events cannot resurrect a cancelled row).
        guard let current = activity(for: id), !current.isFinished else { return }
        switch progress {
        case .classifying:
            update(id) { $0.detail = "Classifying the document" }
            setDetail(id, "Classifying the document")
        case .chunk(let index, let count):
            update(id) { $0.chunkIndex = index; $0.chunkCount = count; $0.detail = $0.generatingDetail }
            setDetail(id, activity(for: id)?.generatingDetail ?? "Generating questions")
        case .generating(let model):
            // Only the model changes here; the chunk stays in the detail and an escalated file stays escalated.
            update(id) {
                $0.model = model
                if $0.phase != .escalated { $0.phase = .generating }
                $0.detail = $0.generatingDetail
            }
            let detail = activity(for: id)?.generatingDetail ?? "Generating questions"
            if var document = session.importQueue.first(where: { $0.id == id }) {
                let status: ImportStatus = document.status == .escalated ? .escalated : .generating
                document.status = status
                document.statusDetail = detail
                document.modelUsed = model.rawValue
                session.updateDocument(document)
                persist { [store = session.store] in try await store.update(status: status, detail: detail, model: model.rawValue, for: id) }
            }
        case .escalated(let reason):
            update(id) { $0.phase = .escalated; $0.model = .opus; $0.detail = "Escalated to Opus" }
            if var document = session.importQueue.first(where: { $0.id == id }) {
                document.status = .escalated
                document.statusDetail = "Escalated to Opus"
                document.modelUsed = ClaudeModel.opus.rawValue
                session.updateDocument(document)
                persist { [store = session.store] in
                    try await store.update(status: .escalated, detail: "Escalated to Opus", model: ClaudeModel.opus.rawValue, for: id)
                }
                if !acknowledgedEscalations.contains(id) {
                    escalationNotice = EscalationNotice(documentId: id, filename: document.filename, reason: reason)
                }
            }
        case .figures(let count):
            if count > 0 { update(id) { $0.detail = "Linking \(count) figure\(count == 1 ? "" : "s")" } }
        case .done:
            break
        }
    }

    // MARK: Figures

    /// Saves the PNGs under `figures/<docId>/<index>.png` and inserts pending `Figure` rows. Returns index → id.
    private func storeFigures(_ figures: [ExtractedFigure], documentId: DocumentID) async throws -> [Int: FigureID] {
        // A rerun (after a cancel, a failure or an interrupted run) replaces the figures of the earlier attempt.
        let stale = try await session.store.deleteFigures(for: documentId, deleteFiles: true)
        if stale > 0 { Self.logger.notice("Removed \(stale) figure row(s) left by an earlier run of \(documentId.raw, privacy: .public)") }
        guard !figures.isEmpty else { return [:] }
        let directory = AppPaths.figures.appendingPathComponent(documentId.raw, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ids: [Int: FigureID] = [:]
        for extracted in figures {
            try Task.checkCancellation()
            let relative = "\(documentId.raw)/\(extracted.index).png"
            try extracted.pngData.write(to: AppPaths.figureURL(relative), options: .atomic)
            let figure = Figure(
                documentId: documentId,
                pageOrIndex: extracted.page ?? extracted.index,
                originalPath: relative,
                kind: .unknown,
                status: .pending,
                caption: extracted.nearbyText.isEmpty ? nil : String(extracted.nearbyText.prefix(200))
            )
            try await session.store.insert(figure)
            ids[extracted.index] = figure.id
        }
        return ids
    }

    /// Runs the FigureAgent over the extracted figures; charts become `.reviewing`, everything else keeps its
    /// original (`.keptOriginal`), and images the agent says are not figures at all (equation fragments, symbols,
    /// icons) are deleted again, including from the questions that cited them. Returns the number of charts found
    /// and the number of images dropped. Failures leave figures pending.
    private func analyseFigures(_ figures: [ExtractedFigure], figureIds: [Int: FigureID], document: inout ImportedDocument) async -> (charts: Int, dropped: Int) {
        guard !figures.isEmpty, session.app.isConnected else { return (0, 0) }
        let agent = FigureAgent(client: session.app.claudeClient, model: runPolicy.pinned ?? .sonnet)
        let batch = figures.prefix(Self.maxAnalysedFigures)
        var charts = 0
        var rejected: [FigureID] = []
        let filename = document.filename
        document = await setStatus(document, .extractingFigures, detail: "Analysing figures (0 of \(batch.count))", model: document.modelUsed)
        update(document.id) { $0.phase = .analysingFigures; $0.detail = "Analysing figures" }
        for (offset, extracted) in batch.enumerated() {
            if Task.isCancelled { break }
            guard let id = figureIds[extracted.index], var figure = try? await session.store.figure(id: id) else { continue }
            let label = "Analysing figures (\(offset + 1) of \(batch.count))"
            update(document.id) { $0.detail = label }
            setDetail(document.id, label)
            do {
                let analysis = try await agent.analyze(png: extracted.pngData, nearbyText: extracted.nearbyText)
                if !analysis.isFigure {
                    Self.logger.notice("Dropping non-figure image \(extracted.index) of \(filename, privacy: .public): \(analysis.caption ?? "", privacy: .public)")
                    try await session.store.delete(figure.id, deleteFile: true)
                    rejected.append(figure.id)
                    continue
                }
                figure.kind = analysis.kind
                figure.chart = analysis.chart
                if let caption = analysis.caption, !caption.isEmpty { figure.caption = caption }
                if analysis.kind == .chart, analysis.chart != nil {
                    figure.status = .reviewing
                    charts += 1
                } else {
                    figure.status = .keptOriginal
                }
                try await session.store.update(figure)
            } catch is CancellationError {
                break
            } catch {
                Self.logger.error("Figure analysis failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !rejected.isEmpty { await stripFigures(rejected, from: document.id) }
        return (charts, rejected.count)
    }

    /// Removes deleted figure ids from the document's questions so nothing points at a missing image.
    private func stripFigures(_ ids: [FigureID], from documentId: DocumentID) async {
        let gone = Set(ids)
        do {
            let questions = try await session.store.questions(in: session.classId, filter: QuestionFilter(documentIds: [documentId]))
            for var question in questions where question.figureIds.contains(where: gone.contains) {
                question.figureIds.removeAll(where: gone.contains)
                try await session.store.update(question)
            }
        } catch {
            Self.logger.error("Could not detach dropped figures: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Status plumbing

    /// The tail of the status-write chain: every persisted status goes through `persist`, so writes reach SQLite
    /// in the order they were requested and a final status can wait for the ones before it.
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    @discardableResult
    private func persist(_ write: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        let previous = writeChain
        let task = Task {
            await previous?.value
            do {
                try await write()
            } catch {
                Self.logger.error("Status update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        writeChain = task
        return task
    }

    private func setStatus(_ document: ImportedDocument, _ status: ImportStatus, detail: String?, model: String?) async -> ImportedDocument {
        var updated = document
        updated.status = status
        updated.statusDetail = detail
        updated.modelUsed = model
        session.updateDocument(updated)
        let id = document.id
        await persist { [store = session.store] in try await store.update(status: status, detail: detail, model: model, for: id) }.value
        return updated
    }

    private func setDetail(_ id: DocumentID, _ detail: String) {
        guard var document = session.importQueue.first(where: { $0.id == id }) else { return }
        document.statusDetail = detail
        session.updateDocument(document)
        let status = document.status, model = document.modelUsed
        persist { [store = session.store] in try await store.update(status: status, detail: detail, model: model, for: id) }
    }

    private func resetToQueued(_ document: ImportedDocument) async {
        // Finish the activity first so any late progress event is ignored, then queue the reset behind every
        // pending status write.
        markCancelled(document.id)
        _ = await setStatus(document, .queued, detail: "Cancelled", model: nil)
    }

    private func markCancelled(_ id: DocumentID) {
        update(id) { $0.phase = .cancelled; $0.detail = "Cancelled" }
    }

    private func update(_ id: DocumentID, _ change: (inout FileActivity) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        change(&activities[index])
    }
}
