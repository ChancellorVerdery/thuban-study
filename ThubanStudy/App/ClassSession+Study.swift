import Foundation
import Observation
import ThubanCore
import os

// MARK: - Per-class study state

/// Study-screen state that outlives the views (web controllers, the results sheet, the composer draft, the
/// tutor stream). `ClassSession` cannot gain stored properties in an extension, so one of these is kept per class
/// in `ClassSession.studyState`.
@MainActor
@Observable
final class StudyState {
    /// The answer form, the transcript and (lazily) the grapher and calculator — one controller per pane.
    let form = QuestionFormWebView.Controller()
    let chat = ChatWebView.Controller()
    /// The tutor composer (text with inline math).
    let composer = ComposerWebView.Controller()
    private(set) var graph: GraphWebView.Controller?
    private(set) var calculator: CalculatorWebView.Controller?

    /// Height reported by the question page; the form hugs it inside a scroll view.
    var formHeight: CGFloat = 0
    /// Figures attached to the current question (those shown as answer options are not among them).
    var figures: [Figure] = []
    /// Answer options that are figures: each one's picture (data URL) and description, by figure.
    var choiceImages: [FigureID: String] = [:]
    var choiceFigureDescriptions: [FigureID: String] = [:]
    @ObservationIgnored var figuresLoadedFor: QuestionID?

    // Grading
    var isGrading = false
    /// Drives `AnswerResultsSheet`.
    var results: GradeResults?

    // Tutor
    var composerText = ""
    var tutorError: TutorError?
    var streamingMessageId: MessageID?
    /// The thread the transcript currently holds (`nil` = class-level thread, unset until first load).
    var loadedThread: TranscriptThread?
    @ObservationIgnored var tutorTask: Task<Void, Never>?

    // Layout
    var graphWidth: CGFloat = 480
    /// The tutor pane's width, dragged by its leading edge; kept across launches.
    var tutorWidth: CGFloat = StudyState.savedTutorWidth {
        didSet { UserDefaults.standard.set(Double(tutorWidth), forKey: Self.tutorWidthKey) }
    }
    static let tutorWidthKey = "studyTutorWidth"
    static var savedTutorWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: tutorWidthKey)
        return saved >= Double(StudyLayout.tutorMinWidth) ? CGFloat(saved) : StudyLayout.tutorWidth
    }
    var calculatorOffset: CGSize = .zero

    enum TutorError: Equatable {
        case notConnected
        /// Credentials exist but were rejected (401/403, refused refresh) or could not be read from the Keychain.
        case reconnect(String)
        case failed(String)
    }

    enum TranscriptThread: Equatable {
        case classLevel
        case question(QuestionID)
    }

    func graphController(desmosKey: String, mode: GraphMode) -> GraphWebView.Controller {
        if let graph {
            if graph.desmosKey != desmosKey { graph.configure(desmosKey: desmosKey) }
            return graph
        }
        let controller = GraphWebView.Controller(desmosKey: desmosKey, mode: mode)
        graph = controller
        return controller
    }

    func calculatorController(desmosKey: String) -> CalculatorWebView.Controller {
        if let calculator {
            // The sticky `config` is replayed on every page load, so a key changed while the panel was closed
            // must replace it (mirrors `graphController`).
            if calculator.desmosKey != desmosKey {
                calculator.configure(desmosKey: desmosKey, forceFallback: desmosKey.isEmpty)
            }
            return calculator
        }
        let controller = CalculatorWebView.Controller(desmosKey: desmosKey)
        calculator = controller
        return controller
    }
}

/// The outcome of "Check answers", shown by `AnswerResultsSheet`.
struct GradeResults: Identifiable {
    struct Row: Identifiable {
        var partId: String
        var prompt: String
        var answerKind: AnswerKind
        var input: String
        var verdict: Verdict
        var id: String { partId }
    }

    let id = UUID()
    var questionId: QuestionID
    var seed: String
    var rows: [Row]
    /// Parts the engine graded (free-response parts are excluded).
    var gradedCount: Int
    var correctCount: Int
    var score: Double
    /// Student-facing grading rules that applied to this question.
    var rules: [String]
    var progress: QuestionProgress?

    var isFullyCorrect: Bool { gradedCount > 0 && correctCount == gradedCount }

    /// The first part that is not correct — what "Ask the tutor about (x)" refers to.
    var firstProblemPart: Row? {
        rows.first { !$0.verdict.isCorrect }
    }
}

// MARK: - ClassSession + Study

extension ClassSession {
    private static var studyStates: [ClassID: StudyState] = [:]

    /// The study-screen state of this class (created on first access).
    var studyState: StudyState {
        if let existing = Self.studyStates[classId] { return existing }
        let state = StudyState()
        Self.studyStates[classId] = state
        // Drop states of classes that no longer exist.
        let live = Set(app.classes.map(\.id))
        Self.studyStates = Self.studyStates.filter { live.contains($0.key) || $0.key == classId }
        return state
    }

    /// Class code · source · Question n of N, for the question pane's eyebrow.
    var questionEyebrow: String {
        var pieces: [String] = []
        if let code = studyClass?.courseCode, !code.isEmpty { pieces.append(code) }
        if let source = currentQuestion?.sourceRef, !source.isEmpty {
            pieces.append(source)
        } else if let tag = currentQuestion?.tags.first, !tag.isEmpty {
            pieces.append(tag)
        }
        if questionCount > 0 {
            pieces.append("Question \(questionNumber) of \(questionCount)" + (isStudyingSelection ? " selected" : "") + (isStudyFiltered ? " filtered" : ""))
        }
        return pieces.joined(separator: " · ")
    }

    /// Counts per mastery status over the study queue.
    var progressCounts: (mastered: Int, learning: Int, new: Int, needsReview: Int) {
        var mastered = 0, learning = 0, new = 0, needsReview = 0
        for question in questions {
            switch status(of: question) {
            case .mastered: mastered += 1
            case .learning: learning += 1
            case .new: new += 1
            case .needsReview: needsReview += 1
            }
        }
        return (mastered, learning, new, needsReview)
    }

    // MARK: Figures

    /// Loads the figures attached to the current question (once per question).
    func loadFigures() async {
        let state = studyState
        guard let question = currentQuestion else {
            state.figures = []
            state.figuresLoadedFor = nil
            return
        }
        guard state.figuresLoadedFor != question.id else { return }
        state.figuresLoadedFor = question.id
        let options = question.choiceFigureIds
        let ids = question.figureIds + options.filter { !question.figureIds.contains($0) }
        guard !ids.isEmpty else {
            state.figures = []
            state.choiceImages = [:]
            state.choiceFigureDescriptions = [:]
            return
        }
        do {
            let figures = try await store.figures(ids: ids)
            // Keep the question's order; answer-option figures appear in their part instead.
            let byId = Dictionary(figures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            state.figures = question.figureIds.filter { !options.contains($0) }.compactMap { byId[$0] }
            let optionFigures = options.compactMap { byId[$0] }
            state.choiceFigureDescriptions = Dictionary(optionFigures.compactMap { f in f.caption.map { (f.id, $0) } }, uniquingKeysWith: { a, _ in a })
            if !optionFigures.isEmpty {
                let images = await ChoiceFigureImages.dataURLs(for: optionFigures, theme: app.theme, engine: app.engine)
                if state.figuresLoadedFor == question.id { state.choiceImages = images }
            } else {
                state.choiceImages = [:]
            }
        } catch {
            Self.logger.error("figures failed: \(error.localizedDescription, privacy: .public)")
            state.figures = []
            state.choiceImages = [:]
        }
    }

    // MARK: Grading

    /// Grades every part of the current instance with the MathEngine, records an `Attempt`, refreshes progress
    /// and fills `studyState.results` for the results sheet.
    func checkAnswers() async {
        let state = studyState
        // `results != nil` means the answer sheet is up: menu key equivalents (⌘⏎) still fire under a window
        // sheet, and grading again would record a duplicate Attempt for the same inputs.
        guard !state.isGrading, state.results == nil, let instance = currentInstance, let question = currentQuestion,
              instance.questionId == question.id else { return }
        state.isGrading = true
        defer { state.isGrading = false }

        var graded: [String: Verdict] = [:]
        var rows: [GradeResults.Row] = []
        for part in instance.parts {
            let input = inputs[part.id] ?? ""
            let verdict = await engine.grade(
                student: input,
                expected: Self.expectedSpec(for: part, in: question),
                conditions: part.conditions,
                kind: part.answerKind
            )
            graded[part.id] = verdict
            rows.append(GradeResults.Row(partId: part.id, prompt: part.prompt, answerKind: part.answerKind, input: input, verdict: verdict))
        }
        // The instance may have changed while grading (regenerate / next); only apply to the same one.
        guard currentInstance?.seed == instance.seed, currentInstance?.questionId == instance.questionId else { return }
        verdicts = graded

        let gradable = instance.parts.filter { $0.answerKind.isAutoGradable }
        let correct = gradable.filter { graded[$0.id]?.isCorrect == true }.count
        let score = gradable.isEmpty ? 0 : Double(correct) / Double(gradable.count)

        let attempt = Attempt(
            questionId: question.id,
            seed: instance.seed,
            responses: inputs.filter { entry in instance.parts.contains { part in part.id == entry.key } },
            verdicts: graded,
            score: score
        )
        let bankDefaults = app.questionBankSettings.defaults
        do {
            try await store.record(attempt, masteryStreak: bankDefaults.masteryThreshold)
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("record attempt failed: \(error.localizedDescription, privacy: .public)")
        }
        await reloadProgress()

        let results = GradeResults(
            questionId: question.id,
            seed: instance.seed,
            rows: rows,
            gradedCount: gradable.count,
            correctCount: correct,
            score: score,
            rules: Self.gradingRules(for: instance),
            progress: progress[question.id]
        )
        state.results = results

        // Settings › Question bank: a fully correct template answer draws fresh numbers right away, so "Try again"
        // (and the next visit to this question) shows a new instance instead of the one just solved.
        if results.isFullyCorrect, bankDefaults.autoRegenerateAfterCorrect, question.kind == .mathTemplate,
           currentInstance?.seed == instance.seed {
            await regenerate()
        }
    }

    /// The answer the engine compares against: the instance's resolved answer, plus the bank part's alternatives
    /// and option text for static questions.
    static func expectedSpec(for part: InstancePart, in question: Question) -> AnswerSpec {
        let bankPart = question.parts.first { $0.id == part.id }
        var spec = bankPart?.answer ?? AnswerSpec()
        if question.kind == .mathTemplate || spec.latex == nil {
            spec.latex = part.answerLatex.isEmpty ? spec.latex : part.answerLatex
        }
        if part.answerKind == .choice || part.answerKind == .text {
            if spec.text == nil || question.kind == .mathTemplate {
                spec.text = part.answerLatex.isEmpty ? spec.text : part.answerLatex
            }
        }
        return spec
    }

    /// Student-facing list of the rules that applied ("Rules the engine applied").
    static func gradingRules(for instance: QuestionInstance) -> [String] {
        var rules: [String] = []
        func add(_ rule: String) { if !rules.contains(rule) { rules.append(rule) } }
        let gradable = instance.parts.filter { $0.answerKind.isAutoGradable }
        if gradable.contains(where: { $0.answerKind == .math || $0.answerKind == .numeric }) {
            add("Any algebraically equivalent form is accepted")
        }
        let multi = gradable.count > 1
        for part in gradable {
            for item in part.conditions.summaryItems {
                add(multi ? "(\(part.id)) \(item)" : item)
            }
        }
        if gradable.contains(where: { $0.answerKind == .choice || $0.answerKind == .text }) {
            add("Text answers are matched ignoring case, spacing and punctuation")
        }
        if instance.parts.contains(where: { $0.answerKind == .freeResponse }) {
            add("Free-response parts are reviewed by the tutor, not scored")
        }
        return rules
    }

    // MARK: Tutor transcript

    /// The thread the tutor pane shows: the current question's, or the class thread when there is no question.
    var currentThread: StudyState.TranscriptThread {
        if let id = currentQuestion?.id { return .question(id) }
        return .classLevel
    }

    private var currentThreadQuestionId: QuestionID? {
        if case .question(let id) = currentThread { return id }
        return nil
    }

    /// Loads the transcript of the current thread from the store when the thread changed.
    func loadTranscriptIfNeeded() async {
        let state = studyState
        let thread = currentThread
        guard state.loadedThread != thread else { return }
        state.loadedThread = thread
        state.tutorError = nil
        // Let a reply in flight finish (and persist what arrived) before the thread is replaced.
        await cancelTutorAndWait()
        let questionId: QuestionID?
        if case .question(let id) = thread { questionId = id } else { questionId = nil }
        var loaded: [TutorMessage] = []
        do {
            loaded = try await store.messages(for: classId, question: questionId)
        } catch {
            Self.logger.error("transcript load failed: \(error.localizedDescription, privacy: .public)")
        }
        guard state.loadedThread == thread else { return }
        transcript = loaded
        state.chat.setTranscript(transcript)
    }

    /// Forgets the current thread (store + view).
    func clearTranscript() async {
        await cancelTutorAndWait()
        transcript = []
        studyState.chat.clear()
        studyState.tutorError = nil
        do {
            try await store.clear(for: classId, question: currentThreadQuestionId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stops a streaming reply. The streaming task observes the cancellation and finishes the reply itself: it keeps
    /// whatever text and tool events arrived, persists them, and resets the streaming state.
    func cancelTutor() {
        studyState.tutorTask?.cancel()
    }

    /// `cancelTutor()` plus waiting for the reply to be wrapped up (persisted or discarded).
    func cancelTutorAndWait() async {
        let state = studyState
        guard let task = state.tutorTask else { return }
        task.cancel()
        await task.value
    }

    /// Asks the tutor for a small hint (never the answer).
    func askForHint() {
        sendToTutor("Give me a small hint for the part I'm stuck on.", solutionRequested: false)
    }

    /// Sends a student message and streams the tutor's reply into the transcript, persisting both.
    func sendToTutor(_ text: String, solutionRequested: Bool) {
        let state = studyState
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTutorStreaming else { return }
        state.tutorError = nil
        let questionId = currentThreadQuestionId

        let studentMessage = TutorMessage(
            classId: classId, questionId: questionId, role: .student, content: trimmed, solutionRequested: solutionRequested
        )
        let history = transcript
        transcript.append(studentMessage)
        state.chat.appendMessage(studentMessage)
        // The student message is persisted together with the reply once something arrived, so a failed or
        // cancelled request never leaves an unanswered message behind in the store.

        var reply = TutorMessage(classId: classId, questionId: questionId, role: .tutor, content: "")
        transcript.append(reply)
        state.streamingMessageId = reply.id
        state.chat.appendMessage(reply, streaming: true)
        isTutorStreaming = true

        let context = tutorContext()
        let handler = StudyToolHandler(session: self)
        let agent = app.makeTutorAgent()
        state.tutorTask = Task { [weak self] in
            guard let self else { return }
            var failure: Error?
            var truncated = false
            do {
                let events = agent.respond(
                    context: context, transcript: history, student: trimmed,
                    solutionRequested: solutionRequested, tools: handler
                )
                for try await event in events {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        reply.content += delta
                        self.replaceTranscriptMessage(reply)
                        state.chat.appendDelta(id: reply.id, text: delta)
                    case .toolEvent(let toolEvent):
                        reply.toolEvents.append(toolEvent)
                        self.replaceTranscriptMessage(reply)
                        state.chat.appendMessage(reply, streaming: true)
                    case .truncated:
                        truncated = true
                    case .done:
                        break
                    }
                }
            } catch {
                failure = error
            }
            guard state.streamingMessageId == reply.id else { return }
            state.streamingMessageId = nil
            self.isTutorStreaming = false
            state.tutorTask = nil

            if let failure {
                if case ThubanError.notConnected = failure {
                    state.tutorError = .notConnected
                } else if case ThubanError.cancelled = failure {
                    // Student moved on; keep any partial text.
                } else if let thuban = failure as? ThubanError, thuban.isCredentialProblem {
                    state.tutorError = .reconnect(thuban.localizedDescription)
                    await self.app.noteCredentialProblem(thuban)
                } else {
                    state.tutorError = .failed(failure.localizedDescription)
                }
            } else if truncated {
                state.tutorError = .failed("The tutor's reply was cut off at its length limit. Ask it to continue from where it stopped.")
            }
            let hasContent = !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !reply.toolEvents.isEmpty
            if hasContent {
                self.replaceTranscriptMessage(reply)
                state.chat.finish(id: reply.id, markdown: reply.content)
                do {
                    try await self.store.append(studentMessage)
                    try await self.store.append(reply)
                } catch {
                    self.lastError = "Could not save the conversation: \(error.localizedDescription)"
                    Self.logger.error("message append failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                // Nothing arrived: drop the empty reply and the unanswered student message; after a failure hand the
                // text back to the composer so it can be sent again.
                self.transcript.removeAll { $0.id == reply.id || $0.id == studentMessage.id }
                state.chat.setTranscript(self.transcript)
                if state.tutorError != nil, state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.composerText = trimmed
                    state.composer.setText(trimmed)
                }
            }
        }
    }

    private func replaceTranscriptMessage(_ message: TutorMessage) {
        if let index = transcript.firstIndex(where: { $0.id == message.id }) {
            transcript[index] = message
        } else {
            transcript.append(message)
        }
    }

    /// Everything the tutor needs about the student's current situation.
    func tutorContext() -> TutorContext {
        TutorContext(
            className: studyClass.map { cls in
                cls.courseCode.map { "\(cls.name) (\($0))" } ?? cls.name
            } ?? "this class",
            style: studyClass?.tutorStyle ?? .socratic,
            instance: currentInstance,
            sourceRef: currentQuestion?.sourceRef,
            questionType: currentQuestion?.type,
            inputs: inputs,
            verdicts: verdicts,
            graphExpressions: visibleGraphExpressions.map(\.latex),
            mayEditGraph: app.tutorMayEditGraph,
            model: app.tutorModel,
            includeReferenceAnswers: true
        )
    }

    // MARK: Tutor tools

    /// Executes one tutor tool call against the session (graph, calculator, reading the student's work).
    func handleTutorTool(name: String, input: JSONValue) -> JSONValue {
        let state = studyState
        let graphTools: Set<String> = [TutorTools.showGraph, TutorTools.graphAddExpression, TutorTools.graphRemoveExpression, TutorTools.graphClear, TutorTools.graphSetViewport]
        if graphTools.contains(name), !app.hasDesmosKey {
            return Self.toolError("The grapher is not configured (no Desmos API key in Settings › Grapher), so nothing can be drawn.")
        }
        switch name {
        case TutorTools.showGraph:
            let mode = GraphMode(rawValue: input["mode"]?.stringValue ?? "2d") ?? .twoD
            showGraph = true
            if graphMode != mode { graphMode = mode }
            tutorEditedAt = Date()
            return ["ok": true, "mode": .string(mode.rawValue)]

        case TutorTools.hideGraph:
            showGraph = false
            return ["ok": true]

        case TutorTools.graphAddExpression:
            guard app.tutorMayEditGraph else { return Self.toolError("The student has disabled tutor graph edits.") }
            guard let id = input["id"]?.stringValue, !id.isEmpty, let latex = input["latex"]?.stringValue, !latex.isEmpty else {
                return Self.toolError("id and latex are required.")
            }
            let expression = GraphExpression(
                id: id,
                latex: latex,
                color: input["color"]?.stringValue,
                dashed: input["dashed"]?.boolValue ?? false,
                label: input["label"]?.stringValue,
                hidden: input["hidden"]?.boolValue ?? false,
                fromTutor: true,
                mode: graphMode
            )
            upsertGraphExpression(expression)
            showGraph = true
            state.graph?.addExpression(expression)
            return ["ok": true, "mode": .string(graphMode.rawValue), "count": .number(Double(visibleGraphExpressions.count))]

        case TutorTools.graphRemoveExpression:
            guard app.tutorMayEditGraph else { return Self.toolError("The student has disabled tutor graph edits.") }
            guard let id = input["id"]?.stringValue else { return Self.toolError("id is required.") }
            guard graphExpressions.contains(where: { $0.id == id }) else { return Self.toolError("No expression with id '\(id)'.") }
            removeGraphExpression(id: id, byTutor: true)
            state.graph?.removeExpression(id: id)
            return ["ok": true]

        case TutorTools.graphClear:
            guard app.tutorMayEditGraph else { return Self.toolError("The student has disabled tutor graph edits.") }
            clearGraph(byTutor: true)
            state.graph?.clear()
            return ["ok": true]

        case TutorTools.graphSetViewport:
            guard app.tutorMayEditGraph else { return Self.toolError("The student has disabled tutor graph edits.") }
            guard let xmin = input["xmin"]?.doubleValue, let xmax = input["xmax"]?.doubleValue,
                  let ymin = input["ymin"]?.doubleValue, let ymax = input["ymax"]?.doubleValue, xmin < xmax, ymin < ymax
            else { return Self.toolError("xmin < xmax and ymin < ymax are required.") }
            guard graphMode == .twoD else { return Self.toolError("The viewport can only be set in 2D mode; the graph is in 3D.") }
            let viewport = GraphViewport(xmin: xmin, xmax: xmax, ymin: ymin, ymax: ymax)
            showGraph = true
            tutorEditedAt = Date()
            // Kept on the session so the pane can apply it once the page is up (see GraphPane.attach).
            graphViewport = viewport
            state.graph?.setViewport(viewport)
            return ["ok": true]

        case TutorTools.showCalculator:
            showCalculator = true
            return ["ok": true]

        case TutorTools.getStudentWork:
            return studentWork()

        default:
            return Self.toolError("Unknown tool '\(name)'.")
        }
    }

    /// Inputs, verdicts and prompts per part — never the answers.
    private func studentWork() -> JSONValue {
        guard let instance = currentInstance else {
            return ["question": .null, "parts": .array([])]
        }
        let parts: [JSONValue] = instance.parts.map { part in
            var object: [String: JSONValue] = [
                "id": .string(part.id),
                "prompt": .string(part.prompt),
                "answerKind": .string(part.answerKind.rawValue),
                "input": .string(inputs[part.id] ?? ""),
                "requirements": .array(part.conditions.summaryItems.map { .string($0) }),
            ]
            if let choices = part.choices { object["choices"] = .array(choices.map { .string($0) }) }
            if let options = part.choiceFigures, !options.isEmpty {
                // The tutor cannot see the pictures: what each option shows, for its explanations only.
                object["choicePictures"] = .array(options.map { .string(studyState.choiceFigureDescriptions[$0] ?? "a figure") })
            }
            if let verdict = verdicts[part.id] {
                object["verdict"] = QuestionFormWebView.Controller.pageVerdict(verdict)
            } else {
                object["verdict"] = .null
            }
            return .object(object)
        }
        return .object([
            "stem": .string(instance.stem),
            "seed": .string(instance.seed),
            "parts": .array(parts),
            "graphMode": .string(graphMode.rawValue),
            "graph": .array(visibleGraphExpressions.map { .string($0.latex) }),
        ])
    }

    private static func toolError(_ message: String) -> JSONValue {
        ["error": .string(message)]
    }
}

/// Bridges `TutorAgent` tool calls to the session on the main actor.
struct StudyToolHandler: TutorToolHandler {
    let session: ClassSession

    func handle(name: String, input: JSONValue) async -> JSONValue {
        await session.handleTutorTool(name: name, input: input)
    }
}
