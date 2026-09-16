import Foundation
import Observation
import ThubanCore
import os

/// State of the Question bank screen for one class: the filter, the filtered rows (from
/// `Store.questions(in:filter:)`), facet counts over the whole bank, and the page.
@MainActor
@Observable
final class QuestionBankModel {
    private static let logger = Logger(subsystem: "com.thuban.study", category: "bank")
    static let pageSize = 50

    /// What the bank's main column shows.
    enum Screen: Equatable {
        case table
        case figures
    }

    let classId: ClassID
    @ObservationIgnored private let session: ClassSession

    // MARK: Filter

    var searchText = "" {
        didSet { if searchText != oldValue { scheduleReload() } }
    }
    /// `nil` = All types.
    var kind: QuestionKind? {
        didSet { if kind != oldValue { reload() } }
    }
    var statuses: Set<ProgressStatus> = [] {
        didSet { if statuses != oldValue { reload() } }
    }
    var documentIds: Set<DocumentID> = [] {
        didSet { if documentIds != oldValue { reload() } }
    }
    var screen: Screen = .table

    // MARK: Rows

    /// Every question of the class (unfiltered), for facet counts.
    private(set) var allQuestions: [Question] = []
    /// The filtered rows in store order.
    private(set) var filtered: [Question] = []
    private(set) var isLoading = false
    private(set) var page = 0
    var selection: Set<QuestionID> = []
    var error: String?

    /// Figures of the class (all documents), for the rail count.
    private(set) var figureCount = 0

    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(session: ClassSession) {
        self.classId = session.classId
        self.session = session
    }

    // MARK: Derived

    var filter: QuestionFilter {
        QuestionFilter(
            kinds: kind.map { [$0] } ?? [],
            statuses: statuses,
            documentIds: documentIds,
            search: searchText
        )
    }

    var hasActiveFilter: Bool { !filter.isEmpty }

    var pageCount: Int { max(1, Int((Double(filtered.count) / Double(Self.pageSize)).rounded(.up))) }

    /// Rows of the current page, numbered from the position in the filtered list.
    var pageRows: [Row] {
        let start = page * Self.pageSize
        guard start < filtered.count else { return [] }
        let end = min(filtered.count, start + Self.pageSize)
        return filtered[start..<end].enumerated().map { offset, question in
            Row(
                question: question,
                number: start + offset + 1,
                status: session.status(of: question),
                progress: session.progress[question.id],
                source: session.sourceLabel(for: question),
                isCurrent: session.currentQuestion?.id == question.id
            )
        }
    }

    /// "1–50 of 124"
    var pageLabel: String {
        guard !filtered.isEmpty else { return "0 of 0" }
        let start = page * Self.pageSize + 1
        let end = min(filtered.count, (page + 1) * Self.pageSize)
        return "\(start)–\(end) of \(filtered.count)"
    }

    var canGoBack: Bool { page > 0 }
    var canGoForward: Bool { page + 1 < pageCount }

    func count(of kind: QuestionKind) -> Int { allQuestions.filter { $0.kind == kind }.count }
    func count(of status: ProgressStatus) -> Int { allQuestions.filter { session.status(of: $0) == status }.count }
    func count(of documentId: DocumentID) -> Int { allQuestions.filter { $0.documentId == documentId }.count }
    var masteredCount: Int { count(of: .mastered) }
    var sourceCount: Int { Set(allQuestions.compactMap(\.documentId)).count }

    /// Documents that contributed at least one question, in import order, with their counts.
    var sources: [(document: ImportedDocument, count: Int)] {
        session.importQueue.compactMap { document in
            let count = count(of: document.id)
            return count > 0 ? (document, count) : nil
        }
    }

    /// Kinds worth a chip: the four the brief names always, `numeric` only when present.
    var kindChips: [QuestionKind] {
        var kinds: [QuestionKind] = [.mathTemplate, .shortAnswer, .multipleChoice, .freeResponse]
        if count(of: .numeric) > 0 { kinds.append(.numeric) }
        return kinds
    }

    var subtitle: String {
        let q = allQuestions.count
        return "\(q) question\(q == 1 ? "" : "s") · \(sourceCount) source\(sourceCount == 1 ? "" : "s") · \(masteredCount) mastered"
    }

    // MARK: Loading

    /// Reloads everything: the class's documents, all questions (facets), figures and the filtered rows.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await session.loadDocuments()
        if session.questions.isEmpty { await session.loadQuestions() } else { await session.reloadProgress() }
        do {
            allQuestions = try await session.store.questions(in: classId, filter: nil)
            var figures = 0
            for document in session.importQueue where document.figureCount > 0 {
                figures += try await session.store.figures(for: document.id).count
            }
            figureCount = figures
        } catch {
            self.error = error.localizedDescription
        }
        await reloadFiltered()
    }

    /// Re-runs the filtered query (after a filter change or an edit).
    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { await reloadFiltered() }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await reloadFiltered()
        }
    }

    private func reloadFiltered() async {
        do {
            let rows = try await session.store.questions(in: classId, filter: filter)
            guard !Task.isCancelled else { return }
            filtered = rows
            if page >= pageCount { page = max(0, pageCount - 1) }
            selection = selection.filter { id in rows.contains { $0.id == id } }
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("Bank query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After an edit/delete/reset: refresh facets, rows and the session's queue.
    func refreshAfterChange() async {
        do {
            allQuestions = try await session.store.questions(in: classId, filter: nil)
        } catch {
            self.error = error.localizedDescription
        }
        await reloadFiltered()
    }

    // MARK: Filter actions

    func toggle(status: ProgressStatus) {
        if statuses.contains(status) { statuses.remove(status) } else { statuses.insert(status) }
    }

    func toggle(document id: DocumentID) {
        if documentIds.contains(id) { documentIds.remove(id) } else { documentIds.insert(id) }
    }

    /// Rail selection: exactly this source (or every source when `nil`).
    func showSource(_ id: DocumentID?) {
        screen = .table
        documentIds = id.map { [$0] } ?? []
    }

    func clearFilters() {
        searchText = ""
        kind = nil
        statuses = []
        documentIds = []
    }

    func nextPage() { if canGoForward { page += 1 } }
    func previousPage() { if canGoBack { page -= 1 } }

    // MARK: Row model

    struct Row: Identifiable {
        var question: Question
        var number: Int
        var status: ProgressStatus
        var progress: QuestionProgress?
        var source: String
        var isCurrent: Bool

        var id: QuestionID { question.id }

        /// The stem as one plain line: Markdown/LaTeX markers stripped.
        var stemLine: String { QuestionBankModel.plainLine(question.stem) }

        /// "92% · 2 d ago" / "—"
        var lastResult: String {
            guard let progress, let score = progress.lastScore else { return "—" }
            let percent = Int((score * 100).rounded())
            guard let date = progress.lastAttemptAt else { return "\(percent)%" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "\(percent)% · \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
    }

    /// Collapses whitespace and strips `$`, `$$`, `\(`/`\)` markers and a few LaTeX commands so a stem fits on one line.
    nonisolated static func plainLine(_ markdown: String) -> String {
        var text = markdown
        for marker in ["$$", "$", "\\(", "\\)", "\\[", "\\]", "**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        let replacements: [(String, String)] = [
            ("\\cdot", "·"), ("\\times", "×"), ("\\pi", "π"), ("\\theta", "θ"), ("\\infty", "∞"),
            ("\\le", "≤"), ("\\ge", "≥"), ("\\ne", "≠"), ("\\pm", "±"), ("\\sqrt", "√"),
            ("\\left", ""), ("\\right", ""), ("\\,", " "), ("\\;", " "), ("\\!", ""),
            ("\\mathrm", ""), ("\\text", ""), ("\\frac", ""), ("\\dfrac", ""), ("\\partial", "∂"),
        ]
        for (command, replacement) in replacements {
            text = text.replacingOccurrences(of: command, with: replacement)
        }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
