import AppKit
import Foundation
import ThubanCore
import WebKit
import os

/// Visual smoke test driven by the `THUBAN_SMOKE=<output dir>` environment variable (see `scripts/smoke.sh`).
/// Seeds demo data into the (temporary, `THUBAN_HOME`) store during `AppModel.load()`, walks the main screens,
/// writes composited screenshots (native chrome + every WKWebView) as PNGs and terminates the app.
@MainActor
enum SmokeHarness {
    static let variable = "THUBAN_SMOKE"
    private static let logger = Logger(subsystem: "com.thuban.study", category: "smoke")

    /// The output directory, when the harness is enabled.
    static var outputDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var isEnabled: Bool { outputDirectory != nil }

    /// Seed that instantiates the tangent-plane template with a = 1, b = 2, so the form shows P(1, 2, f(1, 2)) and
    /// matches the seeded transcript (which talks about f_x(1, 2), (x − 1) and (y − 2)). Instantiation is
    /// deterministic per seed (SplitMix64 through `TemplateSampler`), so the smoke screenshot is stable.
    static let tangentPlaneSeed = "00000023"

    // MARK: Seeding

    /// Inserts the demo class, document, questions, transcript and progress rows (idempotent per fresh home).
    static func seedIfEnabled(store: Store) async {
        guard isEnabled else { return }
        do {
            let existing = try await store.allClasses()
            guard existing.isEmpty else { return }
            try await seed(store: store)
            logger.info("seeded demo data")
        } catch {
            logger.error("seeding failed: \(error.localizedDescription, privacy: .public)")
            fputs("smoke: seeding failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func seed(store: Store) async throws {
        // Deterministic first screenshots regardless of the macOS appearance.
        try await store.set(.theme, ThemeSelection(mode: .light, schemeId: SchemePresets.defaultId, custom: nil))

        let studyClass = StudyClass(name: "Multivariable Calculus", courseCode: "MATH 2210", term: "Fall 2026",
                                    tutorStyle: .socratic, sortOrder: 0)
        try await store.insert(studyClass)
        let classId = studyClass.id

        // A fake imported PDF (a small placeholder file so sizes and paths resolve).
        let documentId = DocumentID.new()
        let storedPath = "\(classId.raw)/\(documentId.raw)-Homework 4 — Partial Derivatives.pdf"
        let fileURL = AppPaths.documentURL(storedPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let placeholder = Data(("%PDF-1.4\n% Thuban smoke placeholder\n" + String(repeating: "0", count: 4096)).utf8)
        try placeholder.write(to: fileURL)
        let document = ImportedDocument(
            id: documentId, classId: classId,
            filename: "Homework 4 — Partial Derivatives.pdf", kind: .pdf, storedPath: storedPath,
            byteCount: placeholder.count, importedAt: Date().addingTimeInterval(-86_400 * 3),
            status: .done, statusDetail: "Done · 6 questions", modelUsed: ClaudeModel.sonnet.rawValue,
            classification: .existingQuestions, questionCount: 6, figureCount: 2
        )
        try await store.insert(document)
        try await seedFigures(store: store, documentId: documentId)

        let base = Date().addingTimeInterval(-86_400 * 3)
        func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }

        // 1. Partial derivatives + tangent plane (math template mirroring the design brief: a = 1, b = 2).
        let partialDerivative = Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q3", kind: .mathTemplate, type: "Tangent planes",
            stem: "Let $f(x, y) = x^2 y + 3xy^3 - 2y$. The surface $z = f(x, y)$ passes through the point $P(1, 2, f(1, 2))$.",
            parts: [
                QuestionPart(id: "a", prompt: "Find $f_x(1, 2)$.", answerKind: .math, answer: AnswerSpec(latex: "28")),
                QuestionPart(id: "b", prompt: "Find $f_y(1, 2)$.", answerKind: .math, answer: AnswerSpec(latex: "35")),
                QuestionPart(id: "c", prompt: "Write the tangent plane to the surface at $P$ as $z = L(x, y)$ and enter $L(x, y)$.",
                             answerKind: .math, answer: AnswerSpec(latex: "22 + 28(x - 1) + 35(y - 2)")),
                QuestionPart(id: "d", prompt: "Find the direction of steepest ascent at $P$ as a unit vector.",
                             answerKind: .math, answer: AnswerSpec(latex: "\\left(\\frac{28}{\\sqrt{2009}}, \\frac{35}{\\sqrt{2009}}\\right)"),
                             conditions: AnswerConditions(rationalizedDenominator: true)),
            ],
            template: MathTemplate(
                params: [
                    TemplateParam(name: "a", kind: .int(min: 1, max: 3)),
                    TemplateParam(name: "b", kind: .int(min: 1, max: 3)),
                ],
                stem: "Let $f(x, y) = x^2 y + 3xy^3 - 2y$. The surface $z = f(x, y)$ passes through the point $P({a}, {b}, f({a}, {b}))$.",
                parts: [
                    TemplatePart(id: "a", prompt: "Find $f_x({a}, {b})$.", answerExpr: "2 a b + 3 b^3"),
                    TemplatePart(id: "b", prompt: "Find $f_y({a}, {b})$.", answerExpr: "a^2 + 9 a b^2 - 2"),
                    TemplatePart(id: "c", prompt: "Write the tangent plane to the surface at $P$ as $z = L(x, y)$ and enter $L(x, y)$.",
                                 answerExpr: "(a^2 b + 3 a b^3 - 2 b) + (2 a b + 3 b^3)(x - a) + (a^2 + 9 a b^2 - 2)(y - b)"),
                    TemplatePart(id: "d", prompt: "Find the direction of steepest ascent at $P$ as a unit vector.",
                                 answerExpr: "\\left(\\frac{2 a b + 3 b^3}{\\sqrt{(2 a b + 3 b^3)^2 + (a^2 + 9 a b^2 - 2)^2}}, \\frac{a^2 + 9 a b^2 - 2}{\\sqrt{(2 a b + 3 b^3)^2 + (a^2 + 9 a b^2 - 2)^2}}\\right)",
                                 conditions: AnswerConditions(rationalizedDenominator: true)),
                ],
                seedNote: "The point P(a, b) varies; the surface is fixed."
            ),
            tags: ["partial derivatives", "tangent plane"], difficulty: 3, createdAt: at(0)
        )

        // 2. Asymptotes of a rational function (math template).
        let asymptotes = Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q1", kind: .mathTemplate, type: "Asymptotes",
            stem: "Let $f(x) = \\dfrac{2x^2 + 1}{x^2 - 4}$.",
            parts: [
                QuestionPart(id: "a", prompt: "The vertical asymptotes are $x = \\pm c$. Find $c$.", answerKind: .math, answer: AnswerSpec(latex: "2")),
                QuestionPart(id: "b", prompt: "The horizontal asymptote is $y = k$. Find $k$.", answerKind: .math, answer: AnswerSpec(latex: "2")),
            ],
            template: MathTemplate(
                params: [
                    TemplateParam(name: "a", kind: .int(min: 2, max: 5)),
                    TemplateParam(name: "b", kind: .int(min: 2, max: 3)),
                ],
                stem: "Let $f(x) = \\dfrac{{a}x^2 + 1}{x^2 - {b}^2}$.",
                parts: [
                    TemplatePart(id: "a", prompt: "The vertical asymptotes are $x = \\pm c$. Find $c$.", answerExpr: "b"),
                    TemplatePart(id: "b", prompt: "The horizontal asymptote is $y = k$. Find $k$.", answerExpr: "a"),
                ]
            ),
            tags: ["asymptotes"], difficulty: 2, createdAt: at(1)
        )

        // 3–4. Static math questions.
        let staticPartial = Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q2", kind: .shortAnswer, type: "Partial derivatives",
            stem: "Let $g(x, y) = \\sin(xy) + e^{x}$.",
            parts: [
                QuestionPart(id: "a", prompt: "Find $g_x(x, y)$.", answerKind: .math, answer: AnswerSpec(latex: "y\\cos(xy) + e^{x}")),
                QuestionPart(id: "b", prompt: "Find $g_y(x, y)$.", answerKind: .math, answer: AnswerSpec(latex: "x\\cos(xy)")),
            ],
            tags: ["partial derivatives"], difficulty: 2, createdAt: at(2)
        )
        let staticLimit = Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q4", kind: .numeric, type: "Limits of two variables",
            stem: "Consider $\\displaystyle \\lim_{(x, y) \\to (0, 0)} \\frac{x^2 y}{x^2 + y^2}$.",
            parts: [
                QuestionPart(id: "a", prompt: "Evaluate the limit (use polar coordinates).", answerKind: .numeric, answer: AnswerSpec(latex: "0")),
            ],
            tags: ["limits"], difficulty: 3, createdAt: at(3)
        )

        // 5. Multiple choice.
        let choices = [
            "$f_{xy} = f_{yx}$ wherever both are continuous",
            "$f_{xy} = -f_{yx}$ everywhere",
            "$f_{xy}$ and $f_{yx}$ are never equal for polynomials",
            "$f_{xy} = f_{yx}$ only when $f$ is linear",
        ]
        let multipleChoice = Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q5", kind: .multipleChoice, type: "Partial derivatives",
            stem: "Which statement does Clairaut's theorem guarantee for a function $f(x, y)$ with continuous second partials?",
            parts: [
                QuestionPart(id: "a", prompt: "Choose one.", answerKind: .choice, answer: AnswerSpec(text: choices[0]), choices: choices),
            ],
            tags: ["mixed partials"], difficulty: 1, createdAt: at(4)
        )

        // 6. Free response.
        let freeResponse = Question(
            classId: classId, documentId: documentId, sourceRef: "Homework 4 · Q6", kind: .freeResponse, type: "Gradient and directional derivatives",
            stem: "The gradient $\\nabla f(P)$ points in the direction of steepest ascent of $f$ at $P$.",
            parts: [
                QuestionPart(id: "a", prompt: "Explain in your own words why this is true, using the directional derivative $D_{\\mathbf{u}} f = \\nabla f \\cdot \\mathbf{u}$.",
                             answerKind: .freeResponse,
                             answer: AnswerSpec(rubric: "Mentions the dot product / cosine of the angle between the gradient and u, and that it is maximised when the angle is zero.")),
            ],
            tags: ["gradient"], difficulty: 3, createdAt: at(5)
        )

        try await store.insert([partialDerivative, asymptotes, staticPartial, staticLimit, multipleChoice, freeResponse])

        // Progress: partial derivative → needsReview (first in the queue), static partial → mastered,
        // limit → learning, the rest new.
        func attempt(_ question: Question, seed: String, correct: Bool, minutes: Int) -> Attempt {
            let verdicts = Dictionary(uniqueKeysWithValues: question.parts.map { part in
                (part.id, Verdict(outcome: correct ? .correct : .incorrect, message: correct ? "Correct." : "Not quite yet."))
            })
            return Attempt(questionId: question.id, seed: seed, responses: [:], verdicts: verdicts,
                           score: correct ? 1 : 0, createdAt: at(minutes))
        }
        try await store.record(attempt(partialDerivative, seed: "4f2a1c07", correct: true, minutes: 10))
        try await store.record(attempt(partialDerivative, seed: "9b13e6d2", correct: true, minutes: 20))
        try await store.record(attempt(partialDerivative, seed: "c0ffee11", correct: false, minutes: 30))
        try await store.record(attempt(staticPartial, seed: "00000000", correct: true, minutes: 40))
        try await store.record(attempt(staticPartial, seed: "00000001", correct: true, minutes: 50))
        try await store.record(attempt(staticLimit, seed: "00000000", correct: true, minutes: 60))

        // Tutor transcript on the first question (from the design brief).
        let lines: [(ChatRole, String)] = [
            (.student, "I got parts a and b but I don't know how to start the tangent plane."),
            (.tutor, "Good — you already have the two numbers the tangent plane needs. What does $f_x(1, 2)$ tell you about how $z$ changes if you nudge $x$ a little while holding $y$ fixed?"),
            (.student, "The slope in the x direction?"),
            (.tutor, "Exactly. So the plane must have that slope in $x$ and $f_y$'s slope in $y$, and it must pass through $P$. Try writing $z - z_0$ in terms of $(x - 1)$ and $(y - 2)$. What is $z_0$ here?"),
        ]
        for (index, line) in lines.enumerated() {
            try await store.append(TutorMessage(
                classId: classId, questionId: partialDerivative.id, role: line.0, content: line.1,
                createdAt: at(31 + index)
            ))
        }
        try await store.set(.lastClass, classId)
    }

    // MARK: Walkthrough

    /// Two charts under review: a direction field with its solution curve, and a cubic read off as points.
    private static func seedFigures(store: Store, documentId: DocumentID) async throws {
        let field = StandardChart(
            chartType: "slopeField", xLabel: "x", yLabel: "y",
            series: [ChartSeries(name: "Solution through (0, 1)", through: [0, 1])],
            xRange: [-3, 3], yRange: [-3, 3], confidence: 0.8, slope: "x-y", arrows: true,
            xStep: 1, yStep: 1, fieldColumns: 24, fieldRows: 24,
            notes: "Window −3…3 on both axes with unit ticks; 24 × 24 arrows; the solution enters at (−3, 2.4), dips to its minimum near (0.7, 0.9) and leaves at (3, 2.1).",
            provenance: StandardChart.stated,
            definition: "part (b): dy/dx = x − y with y(0) = 1",
            checks: [[0, 0, 0], [1, 0, 1], [0, 1, -1], [2, 2, 0], [0, 1], [2, 1.27]],
            verification: ChartVerification(passed: true, summary: "Verified: 6 of 6 points read from the picture agree with dy/dx = x-y.")
        )
        let cubicPoints: [[Double]] = stride(from: -1.5, through: 4.0, by: 0.5).map { x in
            [x, 0.5 * x * x * x - 2 * x * x + x + 1]
        }
        let cubic = StandardChart(
            chartType: "line", xLabel: "x", yLabel: "y",
            series: [ChartSeries(name: "f(x)", points: cubicPoints)],
            xRange: [-2, 5], yRange: [-6, 6], confidence: 0.7
        )
        for (index, chart) in [field, cubic].enumerated() {
            let relative = "\(documentId.raw)/\(index).png"
            let url = AppPaths.figureURL(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try placeholderPNG().write(to: url)
            try await store.insert(Figure(
                documentId: documentId, pageOrIndex: index, originalPath: relative, kind: .chart, chart: chart,
                status: .reviewing,
                caption: index == 0 ? "Direction field of dy/dx = x − y with the solution through (0, 1)." : "A cubic curve read off the figure."
            ))
        }
    }

    /// A 320×240 pale rectangle with a diagonal, standing in for a clipped figure.
    private static func placeholderPNG() -> Data {
        let size = NSSize(width: 320, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.85, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.move(to: NSPoint(x: 20, y: 40))
        path.curve(to: NSPoint(x: 300, y: 200), controlPoint1: NSPoint(x: 120, y: 240), controlPoint2: NSPoint(x: 200, y: 0))
        path.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    /// Starts the screenshot walkthrough once the model has loaded. Returns immediately.
    static func startIfEnabled(app: AppModel) {
        guard let directory = outputDirectory else { return }
        Task { @MainActor in
            if let match = ProcessInfo.processInfo.environment["THUBAN_SMOKE_QUESTION"], !match.isEmpty {
                await captureQuestions(app: app, matches: match.split(separator: "|").map(String.init), directory: directory)
            } else {
                await run(app: app, directory: directory)
            }
        }
    }

    /// `THUBAN_SMOKE_QUESTION=<ref>|<ref>…`: studies each question whose source label contains the text and
    /// captures the window, at the top and scrolled to the answer form (for the data under `THUBAN_HOME`).
    private static func captureQuestions(app: AppModel, matches: [String], directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSApp.activate(ignoringOtherApps: true)
            guard let session = app.selectedSession else { throw ThubanError.store("smoke: no selected class") }
            session.section = .study
            let window = try await waitForMainWindow()
            window.makeKeyAndOrderFront(nil)
            await waitUntil(timeout: 8) { !session.questions.isEmpty && session.studyState.form.bridge.isReady }
            for (offset, match) in matches.enumerated() {
                guard let question = session.questions.first(where: { ($0.sourceRef ?? "").localizedCaseInsensitiveContains(match) }) else {
                    fputs("smoke: no question matches \(match)\n", stderr)
                    continue
                }
                await session.study(question: question)
                await waitUntil(timeout: 10) { session.currentQuestion?.id == question.id && session.currentInstance != nil }
                await sleep(4)
                _ = try await capture(window: window, name: String(format: "q%02d-top", offset + 1), in: directory)
                if let scroll = window.contentView.flatMap(firstScrollView(in:)) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    await sleep(1.5)
                    _ = try await capture(window: window, name: String(format: "q%02d-form", offset + 1), in: directory)
                }
            }
            print("smoke: done")
        } catch {
            fputs("smoke: \(error.localizedDescription)\n", stderr)
        }
        NSApp.terminate(nil)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil, !(String(describing: type(of: scroll)).contains("WK")) { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }

    private static func run(app: AppModel, directory: URL) async {
        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSApp.activate(ignoringOtherApps: true)

            guard let session = app.selectedSession else {
                throw ThubanError.store("smoke: no selected class after load")
            }
            session.section = .study
            let window = try await waitForMainWindow()
            window.makeKeyAndOrderFront(nil)

            // 01 — Study with the form, transcript (and a graph-free layout).
            let state = session.studyState
            await waitUntil(timeout: 6) {
                session.currentInstance != nil && state.form.bridge.isReady && state.chat.bridge.isReady
            }
            // Re-instantiate the first question with the pinned seed once the initial (random) instance is in, so
            // the numbers on screen are the ones the transcript refers to.
            if let question = session.currentQuestion, question.kind == .mathTemplate {
                await session.instantiate(question, seed: tangentPlaneSeed)
                let params = session.currentInstance?.params ?? [:]
                if params["a"] != "1" || params["b"] != "2" {
                    fputs("smoke: WARNING: seed \(tangentPlaneSeed) produced a=\(params["a"] ?? "?") b=\(params["b"] ?? "?"), expected a=1 b=2\n", stderr)
                }
            }
            await sleep(2)
            written.append(try await capture(window: window, name: "01-study", in: directory))

            // 02 — Graph pane with the surface slice and its tangent line.
            session.graphMode = .twoD
            // The brief's 2D example: a rational function with its asymptotes added by the tutor.
            session.upsertGraphExpression(GraphExpression(id: "smoke-f", latex: "f(x) = \\frac{2x^2 + 1}{x^2 - 4}"))
            session.upsertGraphExpression(GraphExpression(id: "smoke-va1", latex: "x = -2", dashed: true, fromTutor: true))
            session.upsertGraphExpression(GraphExpression(id: "smoke-va2", latex: "x = 2", dashed: true, fromTutor: true))
            session.upsertGraphExpression(GraphExpression(id: "smoke-ha", latex: "y = 2", dashed: true, label: "y = 2", fromTutor: true))
            session.upsertGraphExpression(GraphExpression(id: "smoke-pt", latex: "(0, -0.25)", label: "(0, -0.25)", fromTutor: true))
            session.showGraph = true
            await sleep(5)
            written.append(try await capture(window: window, name: "02-study-graph", in: directory))

            // 03 — Calculator overlay and the virtual keyboard.
            session.showCalculator = true
            session.showKeyboard = true
            await sleep(4)
            written.append(try await capture(window: window, name: "03-study-keyboard-calc", in: directory))

            // 04 — Question bank.
            session.showCalculator = false
            session.showKeyboard = false
            session.section = .questionBank
            await sleep(2.5)
            written.append(try await capture(window: window, name: "04-bank", in: directory))

            // 04b — Question bank with several rows selected (selection bar in the footer).
            session.pendingBankSelection = Set(session.questions.prefix(3).map(\.id))
            await sleep(1.5)
            written.append(try await capture(window: window, name: "04b-bank-selection", in: directory))
            session.pendingBankSelection = []
            await sleep(0.5)

            // 05 — Import.
            session.section = .importDocs
            await sleep(2.5)
            written.append(try await capture(window: window, name: "05-import", in: directory))

            // 05b/05c — Figure review: the direction field, then the point-sampled curve.
            session.pendingFigureReview = session.importQueue.first?.id
            await sleep(6)   // Desmos loads in the review pane
            written.append(try await capture(window: window, name: "05b-figure-field", in: directory))
            session.section = .questionBank
            await sleep(0.5)
            session.section = .importDocs
            session.pendingFigureReviewIndex = 1
            session.pendingFigureReview = session.importQueue.first?.id
            await sleep(6)
            written.append(try await capture(window: window, name: "05c-figure-curve", in: directory))
            session.section = .questionBank
            await sleep(0.5)

            // 06 — Settings window.
            app.perform(.openSettings)
            let settings = try await waitForWindow(timeout: 5) { $0.title == "Settings" }
            settings.makeKeyAndOrderFront(nil)
            await sleep(2.5)
            written.append(try await capture(window: settings, name: "06-settings", in: directory))
            settings.orderOut(nil)

            // 07 — Study again in dark mode with the Cobalt scheme.
            app.setAppearanceMode(.dark)
            app.selectScheme(id: "cobalt")
            session.section = .study
            window.makeKeyAndOrderFront(nil)
            await sleep(6)   // the graph page is re-created with the pane and loads Desmos again
            written.append(try await capture(window: window, name: "07-study-dark-cobalt", in: directory))

            for url in written { print("smoke: wrote \(url.path)") }
            print("smoke: done")
        } catch {
            logger.error("smoke failed: \(error.localizedDescription, privacy: .public)")
            fputs("smoke: FAILED: \(error.localizedDescription)\n", stderr)
        }
        NSApp.terminate(nil)
    }

    // MARK: Waiting

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await sleep(0.1)
        }
    }

    private static func waitForMainWindow() async throws -> NSWindow {
        try await waitForWindow(timeout: 10) { window in
            window.isVisible && window.title != "Settings" && window.contentView != nil
                && window.frame.width >= 800 && !(window is NSPanel)
        }
    }

    private static func waitForWindow(timeout: Double, _ predicate: (NSWindow) -> Bool) async throws -> NSWindow {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = NSApp.windows.first(where: predicate) { return window }
            await sleep(0.1)
        }
        throw ThubanError.store("smoke: timed out waiting for a window")
    }

    // MARK: Capture

    /// Renders the window's native content (`cacheDisplay`) and composites every visible `WKWebView` snapshot at
    /// its frame, then writes `<directory>/<name>.png`.
    private static func capture(window: NSWindow, name: String, in directory: URL) async throws -> URL {
        guard let content = window.contentView else { throw ThubanError.store("smoke: window has no content view") }
        let bounds = content.bounds
        guard let nativeRep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw ThubanError.store("smoke: could not create a bitmap for \(name)")
        }
        content.cacheDisplay(in: bounds, to: nativeRep)
        let native = NSImage(size: bounds.size)
        native.addRepresentation(nativeRep)
        if ProcessInfo.processInfo.environment["THUBAN_SMOKE_DEBUG"] != nil,
           let debugPNG = nativeRep.representation(using: .png, properties: [:]) {
            try? debugPNG.write(to: directory.appendingPathComponent("\(name)-native.png"))
        }

        // Web views, positioned in the content view's (unflipped) window-relative space. Only the visible part of
        // each web view is composited (the form is clipped by a scroll view), and a snapshot is skipped when
        // `cacheDisplay` already rendered that region (drawing over it would hide native overlays such as the
        // floating calculator's header).
        let contentOrigin = content.convert(content.bounds, to: nil).origin
        var overlays: [(rect: NSRect, image: NSImage, source: NSRect)] = []
        var skipped = 0
        for webView in subviews(of: content).compactMap({ $0 as? WKWebView }) {
            let visible = webView.visibleRect
            guard !webView.isHiddenOrHasHiddenAncestor, webView.window === window,
                  visible.width > 1, visible.height > 1 else { continue }
            var rect = webView.convert(visible, to: nil)
            rect.origin.x -= contentOrigin.x
            rect.origin.y -= contentOrigin.y
            if !isBlank(nativeRep, region: rect, bounds: bounds, scale: nativeRep.size.width > 0 ? CGFloat(nativeRep.pixelsWide) / bounds.width : 1) {
                skipped += 1
                continue
            }
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            do {
                let image = try await webView.takeSnapshot(configuration: configuration)
                // Snapshot images are unflipped; WKWebView bounds are flipped (origin top-left).
                let sourceY = webView.isFlipped ? webView.bounds.height - visible.maxY : visible.minY
                let source = NSRect(x: visible.minX, y: sourceY, width: visible.width, height: visible.height)
                overlays.append((rect, image, source))
            } catch {
                logger.error("snapshot failed for a web view in \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let scale = window.backingScaleFactor
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw ThubanError.store("smoke: could not allocate the output bitmap") }
        output.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: output) else {
            throw ThubanError.store("smoke: could not create a graphics context")
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        native.draw(in: NSRect(origin: .zero, size: bounds.size))
        for overlay in overlays {
            overlay.image.draw(in: overlay.rect, from: overlay.source, operation: .sourceOver, fraction: 1)
        }
        context.flushGraphics()

        guard let png = output.representation(using: .png, properties: [:]) else {
            throw ThubanError.store("smoke: PNG encoding failed for \(name)")
        }
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        logger.info("wrote \(url.path, privacy: .public) (\(overlays.count) web views composited, \(skipped) already rendered)")
        print("smoke: \(name): \(overlays.count) web view(s) composited, \(skipped) rendered natively")
        return url
    }

    /// True when the native capture holds a single flat colour inside `region` (content-view points, unflipped).
    private static func isBlank(_ rep: NSBitmapImageRep, region: NSRect, bounds: NSRect, scale: CGFloat) -> Bool {
        let clipped = region.intersection(bounds)
        guard !clipped.isEmpty else { return true }
        let steps = 7
        var reference: (CGFloat, CGFloat, CGFloat)?
        for i in 0..<steps {
            for j in 0..<steps {
                let px = clipped.minX + clipped.width * (CGFloat(i) + 0.5) / CGFloat(steps)
                let py = clipped.minY + clipped.height * (CGFloat(j) + 0.5) / CGFloat(steps)
                let x = Int(px * scale)
                let y = Int((bounds.height - py) * scale)   // bitmap rows run top-down
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let sample = (color.redComponent, color.greenComponent, color.blueComponent)
                if let reference {
                    if abs(reference.0 - sample.0) > 0.02 || abs(reference.1 - sample.1) > 0.02 || abs(reference.2 - sample.2) > 0.02 {
                        return false
                    }
                } else {
                    reference = sample
                }
            }
        }
        return true
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + subviews(of: $0) }
    }
}
