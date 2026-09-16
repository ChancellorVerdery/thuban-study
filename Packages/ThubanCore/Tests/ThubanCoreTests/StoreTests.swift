import Foundation
import GRDB
import XCTest
import ZIPFoundation
@testable import ThubanCore

final class StoreTests: XCTestCase {

    // MARK: Fixtures

    /// Whole seconds so database timestamps round-trip exactly.
    private let t0 = Date(timeIntervalSince1970: 1_758_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A store backed by a temporary directory (file database + document/figure folders), removed on teardown.
    private func makeFileStore() throws -> Store {
        let locations = try StoreLocations.temporary()
        let store = try Store.open(locations)
        addTeardownBlock {
            try? store.close()
            try? FileManager.default.removeItem(at: locations.documents.deletingLastPathComponent())
        }
        return store
    }

    /// An in-memory database with temporary document/figure folders.
    private func makeMemoryStore() throws -> Store {
        let locations = try StoreLocations.temporary(inMemoryDatabase: true)
        let store = try Store.open(locations)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: locations.documents.deletingLastPathComponent())
        }
        return store
    }

    private func sampleClass(name: String = "Calculus II", sortOrder: Int = 0) -> StudyClass {
        StudyClass(name: name, courseCode: "MATH 152", term: "Fall 2026", tint: "#3366FF",
                   tutorStyle: .directHints, sortOrder: sortOrder, createdAt: t0)
    }

    private func sampleDocument(classId: ClassID, filename: String = "hw4.pdf") -> ImportedDocument {
        ImportedDocument(classId: classId, filename: filename, kind: .pdf,
                         storedPath: "\(classId.raw)/\(filename)", byteCount: 1234, importedAt: t0)
    }

    private func sampleQuestion(classId: ClassID, documentId: DocumentID? = nil, stem: String = "Solve $x^2 = 4$.",
                                kind: QuestionKind = .shortAnswer, tags: [String] = ["algebra"],
                                createdAt: Date? = nil) -> Question {
        Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q3", kind: kind, stem: stem,
            parts: [
                QuestionPart(id: "a", prompt: "Find $x$.", answerKind: .math,
                             answer: AnswerSpec(latex: "\\pm 2", alternatives: ["2, -2"]),
                             conditions: AnswerConditions(simplified: true)),
                QuestionPart(id: "b", prompt: "Pick one", answerKind: .choice,
                             answer: AnswerSpec(text: "yes"), choices: ["yes", "no"]),
            ],
            tags: tags, difficulty: 2, createdAt: createdAt ?? t0
        )
    }

    private func sampleTemplateQuestion(classId: ClassID) -> Question {
        let template = MathTemplate(
            params: [TemplateParam(name: "a", kind: .int(min: 1, max: 9), exclude: [0]),
                     TemplateParam(name: "v", kind: .choice(["x", "t"]))],
            constraints: ["a \\ne 2"],
            stem: "Differentiate $f({v}) = {a}{v}^2$.",
            parts: [TemplatePart(id: "a", prompt: "Find $f'({v})$.", answerExpr: "2a v",
                                 conditions: AnswerConditions(simplified: true))],
            seedNote: "a varies"
        )
        return Question(classId: classId, kind: .mathTemplate, stem: template.stem,
                        parts: [QuestionPart(id: "a", prompt: "Find the derivative.")],
                        template: template, tags: ["derivatives"], difficulty: 4, createdAt: t0)
    }

    private func attempt(on question: Question, seed: String, correct: Bool, at date: Date) -> Attempt {
        let verdict = Verdict(outcome: correct ? .correct : .incorrect, message: correct ? "" : "Not quite")
        return Attempt(questionId: question.id, seed: seed, responses: ["a": correct ? "\\pm 2" : "3"],
                       verdicts: ["a": verdict], score: correct ? 1 : 0, createdAt: date)
    }

    private func writeFile(_ relativePath: String, under root: URL, bytes: Int = 64) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    // MARK: Migrations and opening

    func testMigrationsCreateAllTablesOnTempFile() async throws {
        let locations = try StoreLocations.temporary()
        addTeardownBlock { try? FileManager.default.removeItem(at: locations.documents.deletingLastPathComponent()) }

        let store = try Store.open(locations)
        let tables = try await store.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for table in Store.tableNames {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
        let applied = try await store.queue.read { db in try Store.migrator.appliedIdentifiers(db) }
        XCTAssertEqual(applied, ["v1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.database?.path ?? ""))
        try store.close()

        // Reopening the same file is idempotent and keeps data.
        let reopened = try Store.open(locations)
        try await reopened.insert(sampleClass())
        try reopened.close()
        let again = try Store.open(locations)
        let classes = try await again.allClasses()
        XCTAssertEqual(classes.count, 1)
        try again.close()
    }

    func testInMemoryStoreHasSchemaAndForeignKeys() async throws {
        let store = try Store.inMemory()
        let (tables, foreignKeys) = try await store.queue.read { db -> (Int, Bool) in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'") ?? 0
            let fk = try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
            return (count, fk)
        }
        XCTAssertGreaterThanOrEqual(tables, Store.tableNames.count)
        XCTAssertTrue(foreignKeys)
        XCTAssertNil(store.locations.database)
    }

    // MARK: Classes

    func testClassCRUD() async throws {
        let store = try makeMemoryStore()
        let second = sampleClass(name: "Physics", sortOrder: 1)
        let first = sampleClass(name: "Calculus II", sortOrder: 0)
        try await store.insert(second)
        try await store.insert(first)

        let all = try await store.allClasses()
        XCTAssertEqual(all, [first, second])

        var edited = first
        edited.name = "Calculus III"
        edited.tutorStyle = .exam
        edited.tint = nil
        try await store.update(edited)
        let fetched = try await store.studyClass(id: first.id)
        XCTAssertEqual(fetched, edited)

        try await store.reorderClasses([second.id, first.id])
        let reordered = try await store.allClasses().map(\.name)
        XCTAssertEqual(reordered, ["Physics", "Calculus III"])

        try await store.delete(first.id, deleteFiles: false)
        let remaining = try await store.allClasses()
        XCTAssertEqual(remaining.map(\.id), [second.id])
    }

    func testUpdatingMissingClassThrowsStoreError() async throws {
        let store = try makeMemoryStore()
        do {
            try await store.update(sampleClass())
            XCTFail("expected an error")
        } catch let error as ThubanError {
            guard case .store = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    // MARK: Documents

    func testDocumentCRUD() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        var doc = sampleDocument(classId: studyClass.id)
        let later = ImportedDocument(classId: studyClass.id, filename: "notes.md", kind: .markdown,
                                     storedPath: "\(studyClass.id.raw)/notes.md", importedAt: at(60))
        try await store.insert(doc)
        try await store.insert(later)

        let listed = try await store.documents(in: studyClass.id)
        XCTAssertEqual(listed.map(\.filename), ["notes.md", "hw4.pdf"], "newest import first")
        XCTAssertEqual(listed[1], doc)

        try await store.update(status: .generating, detail: "Reading pages 4–9 of 22", model: "claude-sonnet-5", for: doc.id)
        try await store.update(classification: .existingQuestions, questionCount: 7, figureCount: 2, for: doc.id)
        let updated = try await store.document(id: doc.id)
        XCTAssertEqual(updated?.status, .generating)
        XCTAssertEqual(updated?.statusDetail, "Reading pages 4–9 of 22")
        XCTAssertEqual(updated?.modelUsed, "claude-sonnet-5")
        XCTAssertEqual(updated?.classification, .existingQuestions)
        XCTAssertEqual(updated?.questionCount, 7)
        XCTAssertEqual(updated?.figureCount, 2)

        doc.status = .done
        doc.byteCount = 9999
        try await store.update(doc)
        let replaced = try await store.document(id: doc.id)
        XCTAssertEqual(replaced, doc)

        try await store.delete(doc.id)
        let afterDelete = try await store.documents(in: studyClass.id)
        XCTAssertEqual(afterDelete.map(\.id), [later.id])

        do {
            try await store.update(status: .failed, detail: nil, model: nil, for: doc.id)
            XCTFail("expected an error for a missing document")
        } catch let error as ThubanError {
            guard case .store = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    // MARK: Questions

    func testQuestionCRUDWithNestedJSON() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let doc = sampleDocument(classId: studyClass.id)
        try await store.insert(doc)

        let plain = sampleQuestion(classId: studyClass.id, documentId: doc.id)
        let templated = sampleTemplateQuestion(classId: studyClass.id)
        try await store.insert([plain, templated])

        let fetchedPlain = try await store.question(id: plain.id)
        XCTAssertEqual(fetchedPlain, plain)
        let fetchedTemplate = try await store.question(id: templated.id)
        XCTAssertEqual(fetchedTemplate, templated)
        XCTAssertEqual(fetchedTemplate?.template?.params.count, 2)

        var edited = plain
        edited.stem = "Solve $x^2 = 9$."
        edited.tags = ["algebra", "quadratics"]
        edited.figureIds = [FigureID.new()]
        edited.parts[0].answer.latex = "\\pm 3"
        try await store.update(edited)
        let updated = try await store.question(id: plain.id)
        XCTAssertEqual(updated, edited)

        let all = try await store.questions(in: studyClass.id, filter: nil)
        XCTAssertEqual(all.count, 2)
        let count = try await store.questionCount(in: studyClass.id)
        XCTAssertEqual(count, 2)

        try await store.delete(templated.id)
        let remaining = try await store.questions(in: studyClass.id, filter: nil)
        XCTAssertEqual(remaining.map(\.id), [plain.id])
        let missing = try await store.question(id: templated.id)
        XCTAssertNil(missing)
    }

    func testQuestionFilterByKindDocumentAndSearch() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let doc = sampleDocument(classId: studyClass.id)
        try await store.insert(doc)

        let q1 = sampleQuestion(classId: studyClass.id, documentId: doc.id, stem: "Integrate $\\sin x$.",
                                kind: .shortAnswer, tags: ["integrals"], createdAt: at(1))
        let q2 = sampleQuestion(classId: studyClass.id, stem: "Which is 100%?", kind: .multipleChoice,
                                tags: ["percent_rate"], createdAt: at(2))
        let q3 = sampleTemplateQuestion(classId: studyClass.id)
        try await store.insert([q1, q2, q3])

        let byKind = try await store.questions(in: studyClass.id, filter: QuestionFilter(kinds: [.mathTemplate, .multipleChoice]))
        XCTAssertEqual(Set(byKind.map(\.id)), [q2.id, q3.id])

        let byDocument = try await store.questions(in: studyClass.id, filter: QuestionFilter(documentIds: [doc.id]))
        XCTAssertEqual(byDocument.map(\.id), [q1.id])

        let byStem = try await store.questions(in: studyClass.id, filter: QuestionFilter(search: "  SIN x "))
        XCTAssertEqual(byStem.map(\.id), [q1.id])

        let byTag = try await store.questions(in: studyClass.id, filter: QuestionFilter(search: "percent_rate"))
        XCTAssertEqual(byTag.map(\.id), [q2.id])

        let literalPercent = try await store.questions(in: studyClass.id, filter: QuestionFilter(search: "100%"))
        XCTAssertEqual(literalPercent.map(\.id), [q2.id])

        let escapedWildcard = try await store.questions(in: studyClass.id, filter: QuestionFilter(search: "%"))
        XCTAssertEqual(escapedWildcard.map(\.id), [q2.id], "a bare % must not match everything")

        let combined = try await store.questions(in: studyClass.id, filter: QuestionFilter(kinds: [.shortAnswer], search: "Homework 4"))
        XCTAssertEqual(combined.map(\.id), [q1.id])

        let none = try await store.questions(in: studyClass.id, filter: QuestionFilter(search: "nowhere"))
        XCTAssertTrue(none.isEmpty)
    }

    func testQuestionFilterByProgressStatus() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let fresh = sampleQuestion(classId: studyClass.id, stem: "fresh", createdAt: at(1))
        let learning = sampleQuestion(classId: studyClass.id, stem: "learning", createdAt: at(2))
        let mastered = sampleQuestion(classId: studyClass.id, stem: "mastered", createdAt: at(3))
        try await store.insert([fresh, learning, mastered])

        try await store.record(attempt(on: learning, seed: "00000001", correct: true, at: at(10)))
        try await store.record(attempt(on: mastered, seed: "00000001", correct: true, at: at(11)))
        try await store.record(attempt(on: mastered, seed: "00000002", correct: true, at: at(12)))

        let newOnly = try await store.questions(in: studyClass.id, filter: QuestionFilter(statuses: [.new]))
        XCTAssertEqual(newOnly.map(\.id), [fresh.id])
        let inProgress = try await store.questions(in: studyClass.id, filter: QuestionFilter(statuses: [.learning, .mastered]))
        XCTAssertEqual(inProgress.map(\.id), [learning.id, mastered.id])
        let review = try await store.questions(in: studyClass.id, filter: QuestionFilter(statuses: [.needsReview]))
        XCTAssertTrue(review.isEmpty)
    }

    // MARK: Figures

    func testFigureCRUD() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let doc = sampleDocument(classId: studyClass.id)
        try await store.insert(doc)

        let chart = StandardChart(chartType: "line", xLabel: "t", yLabel: "v",
                                  series: [ChartSeries(name: "v(t)", points: [[0, 0], [1, 2.5]], color: "#FF0000"),
                                           ChartSeries(name: "fit", latex: "2.5x")],
                                  xRange: [0, 1], yRange: [0, 3], confidence: 0.8)
        let second = Figure(documentId: doc.id, pageOrIndex: 2, originalPath: "\(doc.id.raw)/p2.png", kind: .chart,
                            chart: chart, status: .accepted, caption: "Velocity")
        let first = Figure(documentId: doc.id, pageOrIndex: 1, originalPath: "\(doc.id.raw)/p1.png")
        try await store.insert(second)
        try await store.insert(first)

        let listed = try await store.figures(for: doc.id)
        XCTAssertEqual(listed, [first, second])
        XCTAssertEqual(listed[1].chart, chart)

        var edited = first
        edited.kind = .diagram
        edited.status = .keptOriginal
        edited.caption = "Free body diagram"
        try await store.update(edited)
        let fetched = try await store.figure(id: first.id)
        XCTAssertEqual(fetched, edited)

        let byIds = try await store.figures(ids: [second.id, FigureID.new(), first.id])
        XCTAssertEqual(byIds.map(\.id), [second.id, first.id])

        try await store.delete(second.id)
        let remaining = try await store.figures(for: doc.id)
        XCTAssertEqual(remaining.map(\.id), [first.id])
    }

    // MARK: Attempts and progress

    func testRecordAttemptStoresAttemptAndProgressAtomically() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let question = sampleQuestion(classId: studyClass.id)
        try await store.insert([question])

        let wrong = attempt(on: question, seed: "0000abcd", correct: false, at: at(5))
        let right = attempt(on: question, seed: "0000abce", correct: true, at: at(10))
        try await store.record(wrong)
        try await store.record(right)

        let attempts = try await store.attempts(for: question.id)
        XCTAssertEqual(attempts, [wrong, right])
        XCTAssertEqual(attempts[0].verdicts["a"]?.outcome, .incorrect)

        let progress = try await store.progress(in: studyClass.id)
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress[0], QuestionProgress(questionId: question.id, status: .learning, streak: 1,
                                                     lastAttemptAt: at(10), lastScore: 1))

        // An attempt on an unknown question is rejected and nothing is written.
        let orphan = Attempt(questionId: QuestionID.new(), seed: "00000000", score: 1, createdAt: at(20))
        do {
            try await store.record(orphan)
            XCTFail("expected an error")
        } catch let error as ThubanError {
            guard case .store = error else { return XCTFail("unexpected error \(error)") }
        }
        let total = try await store.queue.read { db in try Attempt.fetchCount(db) }
        XCTAssertEqual(total, 2)

        try await store.resetProgress(for: question.id)
        let reset = try await store.progress(for: question.id)
        XCTAssertEqual(reset, QuestionProgress(questionId: question.id))
        let cleared = try await store.attempts(for: question.id)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testProgressRulesNewLearningMasteredNeedsReview() {
        let id = QuestionID.new()
        let start = QuestionProgress(questionId: id)
        XCTAssertEqual(start.status, .new)

        let learning = ProgressRules.apply(current: start, verdictScore: 1, at: at(1))
        XCTAssertEqual(learning.status, .learning)
        XCTAssertEqual(learning.streak, 1)
        XCTAssertEqual(learning.lastAttemptAt, at(1))
        XCTAssertEqual(learning.lastScore, 1)

        let mastered = ProgressRules.apply(current: learning, verdictScore: 1, at: at(2))
        XCTAssertEqual(mastered.status, .mastered)
        XCTAssertEqual(mastered.streak, 2)

        let stillMastered = ProgressRules.apply(current: mastered, verdictScore: 1, at: at(3))
        XCTAssertEqual(stillMastered.status, .mastered)
        XCTAssertEqual(stillMastered.streak, 3)

        let needsReview = ProgressRules.apply(current: stillMastered, verdictScore: 0.5, at: at(4))
        XCTAssertEqual(needsReview.status, .needsReview)
        XCTAssertEqual(needsReview.streak, 0)
        XCTAssertEqual(needsReview.lastScore, 0.5)

        let stillReview = ProgressRules.apply(current: needsReview, verdictScore: 0, at: at(5))
        XCTAssertEqual(stillReview.status, .needsReview)

        let recovering = ProgressRules.apply(current: stillReview, verdictScore: 1, at: at(6))
        XCTAssertEqual(recovering.status, .learning)
        XCTAssertEqual(recovering.streak, 1)

        let remastered = ProgressRules.apply(current: recovering, verdictScore: 1, at: at(7))
        XCTAssertEqual(remastered.status, .mastered)

        // Wrong from new goes to learning (the question has been attempted) and never straight to needsReview.
        let wrongFirst = ProgressRules.apply(current: start, verdictScore: 0, at: at(8))
        XCTAssertEqual(wrongFirst.status, .learning)
        XCTAssertEqual(wrongFirst.streak, 0)
    }

    func testRetryOnSameInstanceDoesNotExtendStreak() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let question = sampleQuestion(classId: studyClass.id)
        try await store.insert([question])

        try await store.record(attempt(on: question, seed: "seed0001", correct: false, at: at(1)))
        try await store.record(attempt(on: question, seed: "seed0001", correct: true, at: at(2)))
        var progress = try await store.progress(for: question.id)
        XCTAssertEqual(progress.status, .learning)
        XCTAssertEqual(progress.streak, 0, "a corrected retry is not a first-try success")

        try await store.record(attempt(on: question, seed: "seed0002", correct: true, at: at(3)))
        try await store.record(attempt(on: question, seed: "seed0003", correct: true, at: at(4)))
        progress = try await store.progress(for: question.id)
        XCTAssertEqual(progress.status, .mastered)
        XCTAssertEqual(progress.streak, 2)

        // The pure rule agrees.
        let viaRules = ProgressRules.apply(current: QuestionProgress(questionId: question.id, status: .learning),
                                           verdictScore: 1, isFirstTry: false, at: at(5))
        XCTAssertEqual(viaRules.streak, 0)
        XCTAssertEqual(viaRules.status, .learning)
    }

    // MARK: Messages

    func testMessagesPerThread() async throws {
        let store = try makeMemoryStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let question = sampleQuestion(classId: studyClass.id)
        try await store.insert([question])

        let general1 = TutorMessage(classId: studyClass.id, role: .student, content: "Hi", createdAt: at(1))
        let general2 = TutorMessage(classId: studyClass.id, role: .tutor, content: "Hello! $x$", createdAt: at(2))
        let event = ToolEvent(id: "toolu_1", name: "graph_add_expression", summary: "Added y = 2x + 1",
                              input: ["latex": "y=2x+1", "color": 3])
        let scoped = TutorMessage(classId: studyClass.id, questionId: question.id, role: .tutor, content: "Look at the graph",
                                  toolEvents: [event], solutionRequested: true, createdAt: at(1))
        try await store.append(general2)
        try await store.append(general1)
        try await store.append(scoped)

        let general = try await store.messages(for: studyClass.id, question: nil)
        XCTAssertEqual(general, [general1, general2])
        let thread = try await store.messages(for: studyClass.id, question: question.id)
        XCTAssertEqual(thread, [scoped])
        XCTAssertEqual(thread[0].toolEvents[0].input?["latex"], "y=2x+1")

        try await store.clear(for: studyClass.id, question: nil)
        let clearedGeneral = try await store.messages(for: studyClass.id, question: nil)
        XCTAssertTrue(clearedGeneral.isEmpty)
        let keptThread = try await store.messages(for: studyClass.id, question: question.id)
        XCTAssertEqual(keptThread.count, 1)

        try await store.clear(for: studyClass.id, question: question.id)
        let clearedThread = try await store.messages(for: studyClass.id, question: question.id)
        XCTAssertTrue(clearedThread.isEmpty)
    }

    // MARK: Settings

    func testSettingsRoundTrip() async throws {
        let store = try makeMemoryStore()
        let classId = ClassID.new()
        try await store.set(.lastClass, classId)
        try await store.set(.desmosKey, "abc-123")
        try await store.set(.tutorMayEditGraph, true)
        try await store.set(.windowFrame, [10.5, 20, 800, 600])
        try await store.set(.modelPolicy, ModelPolicy(defaultModel: .opus, allowEscalation: false, pinned: .sonnet))

        let last = try await store.get(.lastClass, as: ClassID.self)
        XCTAssertEqual(last, classId)
        let key = try await store.get(.desmosKey, as: String.self)
        XCTAssertEqual(key, "abc-123")
        let flag = try await store.get(.tutorMayEditGraph, as: Bool.self)
        XCTAssertEqual(flag, true)
        let frame = try await store.get(.windowFrame, as: [Double].self)
        XCTAssertEqual(frame, [10.5, 20, 800, 600])
        let policy = try await store.get(.modelPolicy, as: ModelPolicy.self)
        XCTAssertEqual(policy, ModelPolicy(defaultModel: .opus, allowEscalation: false, pinned: .sonnet))

        let missing = try await store.get(.onboardingDone, as: Bool.self)
        XCTAssertNil(missing)

        try await store.set(.desmosKey, "replaced")
        let replaced = try await store.get(.desmosKey, as: String.self)
        XCTAssertEqual(replaced, "replaced")

        let keys = try await store.settingsKeys()
        XCTAssertEqual(keys.map(\.rawValue), ["desmosKey", "lastClass", "modelPolicy", "tutorMayEditGraph", "windowFrame"])

        try await store.remove(.desmosKey)
        let removed = try await store.get(.desmosKey, as: String.self)
        XCTAssertNil(removed)

        do {
            _ = try await store.get(.tutorMayEditGraph, as: ModelPolicy.self)
            XCTFail("expected a decoding error")
        } catch let error as ThubanError {
            guard case .store = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    // MARK: Cascade delete

    func testDeleteClassCascadesAndRemovesFiles() async throws {
        let store = try makeFileStore()
        let studyClass = sampleClass()
        let other = sampleClass(name: "Other", sortOrder: 1)
        try await store.insert(studyClass)
        try await store.insert(other)
        let doc = sampleDocument(classId: studyClass.id)
        let otherDoc = sampleDocument(classId: other.id, filename: "keep.pdf")
        try await store.insert(doc)
        try await store.insert(otherDoc)
        let figure = Figure(documentId: doc.id, pageOrIndex: 1, originalPath: "\(doc.id.raw)/p1.png")
        try await store.insert(figure)
        let question = sampleQuestion(classId: studyClass.id, documentId: doc.id)
        try await store.insert([question])
        try await store.record(attempt(on: question, seed: "00000001", correct: true, at: at(1)))
        try await store.append(TutorMessage(classId: studyClass.id, questionId: question.id, role: .tutor, content: "x"))
        try await store.append(TutorMessage(classId: studyClass.id, role: .student, content: "y"))

        let docFile = try writeFile(doc.storedPath, under: store.locations.documents)
        let keptFile = try writeFile(otherDoc.storedPath, under: store.locations.documents)
        let figureFile = try writeFile(figure.originalPath, under: store.locations.figures)

        try await store.delete(studyClass.id, deleteFiles: true)

        let counts = try await store.queue.read { db -> [String: Int] in
            var counts: [String: Int] = [:]
            for table in ["documents", "questions", "figures", "attempts", "progress", "messages"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
            return counts
        }
        XCTAssertEqual(counts, ["documents": 1, "questions": 0, "figures": 0, "attempts": 0, "progress": 0, "messages": 0])
        let classes = try await store.allClasses()
        XCTAssertEqual(classes.map(\.id), [other.id])

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: docFile.path))
        XCTAssertFalse(fm.fileExists(atPath: figureFile.path))
        XCTAssertFalse(fm.fileExists(atPath: docFile.deletingLastPathComponent().path), "empty class folder pruned")
        XCTAssertTrue(fm.fileExists(atPath: keptFile.path))
        XCTAssertTrue(fm.fileExists(atPath: store.locations.documents.path), "root directory survives")
    }

    func testDeleteClassWithoutDeleteFilesKeepsFiles() async throws {
        let store = try makeFileStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let doc = sampleDocument(classId: studyClass.id)
        try await store.insert(doc)
        let docFile = try writeFile(doc.storedPath, under: store.locations.documents)

        try await store.delete(studyClass.id, deleteFiles: false)
        let docs = try await store.documents(in: studyClass.id)
        XCTAssertTrue(docs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: docFile.path))
    }

    func testDeleteDocumentCascadesToFiguresAndQuestions() async throws {
        let store = try makeFileStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let doc = sampleDocument(classId: studyClass.id)
        try await store.insert(doc)
        let figure = Figure(documentId: doc.id, pageOrIndex: 1, originalPath: "\(doc.id.raw)/p1.png")
        try await store.insert(figure)
        let fromDoc = sampleQuestion(classId: studyClass.id, documentId: doc.id)
        let standalone = sampleQuestion(classId: studyClass.id)
        try await store.insert([fromDoc, standalone])
        let docFile = try writeFile(doc.storedPath, under: store.locations.documents)
        let figureFile = try writeFile(figure.originalPath, under: store.locations.figures)

        try await store.delete(doc.id, deleteFiles: true)

        let figures = try await store.figures(for: doc.id)
        XCTAssertTrue(figures.isEmpty)
        let questions = try await store.questions(in: studyClass.id, filter: nil)
        XCTAssertEqual(questions.map(\.id), [standalone.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: docFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: figureFile.path))
    }

    // MARK: Files and paths

    func testRelativePathsCannotEscapeTheirRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/thuban-root", isDirectory: true)
        XCTAssertEqual(Store.resolve("abc/file.pdf", under: root)?.path, "/tmp/thuban-root/abc/file.pdf")
        XCTAssertNil(Store.resolve("../etc/passwd", under: root))
        XCTAssertNil(Store.resolve("abc/../../x", under: root))
        XCTAssertNil(Store.resolve("/absolute", under: root))
        XCTAssertNil(Store.resolve("   ", under: root))
        XCTAssertEqual(Store.escapeLike("50%_a\\b"), "50\\%\\_a\\\\b")
    }

    func testStorageSizeCountsDatabaseAndFiles() async throws {
        let store = try makeFileStore()
        try await store.insert(sampleClass())
        let empty = try await store.storageSize()
        XCTAssertGreaterThan(empty, 0, "the database file itself counts")

        _ = try writeFile("c/a.pdf", under: store.locations.documents, bytes: 1000)
        _ = try writeFile("c/b.png", under: store.locations.figures, bytes: 500)
        let withFiles = try await store.storageSize()
        XCTAssertGreaterThanOrEqual(withFiles, empty + 1500)

        let memory = try makeMemoryStore()
        let memorySize = try await memory.storageSize()
        XCTAssertEqual(memorySize, 0)
    }

    func testExportArchiveContainsDatabaseAndFiles() async throws {
        let store = try makeFileStore()
        let studyClass = sampleClass()
        try await store.insert(studyClass)
        let doc = sampleDocument(classId: studyClass.id)
        try await store.insert(doc)
        _ = try writeFile(doc.storedPath, under: store.locations.documents)
        _ = try writeFile("\(doc.id.raw)/p1.png", under: store.locations.figures)

        let exportURL = store.locations.documents.deletingLastPathComponent()
            .appendingPathComponent("exports/backup.zip")
        try await store.exportArchive(to: exportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        let archive = try Archive(url: exportURL, accessMode: .read)
        let paths = Set(archive.map(\.path))
        XCTAssertTrue(paths.contains("thuban.sqlite"), "\(paths)")
        XCTAssertTrue(paths.contains("documents/\(doc.storedPath)"), "\(paths)")
        XCTAssertTrue(paths.contains("figures/\(doc.id.raw)/p1.png"), "\(paths)")

        // The exported database is a usable snapshot with the same rows.
        let extracted = exportURL.deletingLastPathComponent().appendingPathComponent("extracted.sqlite")
        guard let entry = archive["thuban.sqlite"] else { return XCTFail("no database entry") }
        _ = try archive.extract(entry, to: extracted)
        let snapshot = try Store.open(StoreLocations(database: extracted, documents: store.locations.documents,
                                                     figures: store.locations.figures))
        let classes = try await snapshot.allClasses()
        XCTAssertEqual(classes, [studyClass])
        try snapshot.close()

        // Exporting again replaces the previous archive.
        try await store.exportArchive(to: exportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
    }
}
