import AppKit
import Foundation
import Network
import StudyGraph
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

    /// A smoke run seeds demo data and saves graph rows, so it may only run against a temporary `THUBAN_HOME`. Called
    /// before the model opens any store or credentials: with `THUBAN_SMOKE` set and `THUBAN_HOME` unset, pointing
    /// at the default Application Support folder, or holding sign-in credentials, the app exits at once.
    static func exitIfPointedAtLiveData() {
        guard isEnabled else { return }
        let override = ProcessInfo.processInfo.environment[AppPaths.homeOverrideVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = AppPaths.baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Thuban Study", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let hasCredentials = FileManager.default.fileExists(atPath: base.appendingPathComponent("credentials.json").path)
        guard override.isEmpty || base.path == live?.path || hasCredentials else { return }
        fputs("smoke: refusing to run: THUBAN_SMOKE needs THUBAN_HOME set to a temporary directory without credentials (got \(override.isEmpty ? "none" : base.path))\n", stderr)
        exit(64)
    }

    // MARK: Offline trap

    static let proxyTrapVariable = "THUBAN_SMOKE_PROXY_TRAP"

    /// `OFFLINE=1` smoke: WebKit loads run in WebKit's own networking process, which the sandbox around the app does
    /// not reach, so `THUBAN_SMOKE_PROXY_TRAP=127.0.0.1:<port>` sends every WebKit connection (the default website
    /// data store, which every Study and kit web view uses) to a listener that scripts/smoke.sh runs: it records each
    /// attempt and never forwards it. Must run before any web view exists.
    static func installProxyTrapIfRequested() {
        guard isEnabled, let raw = ProcessInfo.processInfo.environment[proxyTrapVariable],
              let colon = raw.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(raw[raw.index(after: colon)...])) else { return }
        let host = NWEndpoint.Host(String(raw[..<colon]))
        WKWebsiteDataStore.default().proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: host, port: port))]
        print("smoke: WebKit network trapped at \(raw)")
    }

    /// Proves the trap: a web view load of a real site must fail (smoke.sh then finds the probe host in the trap's
    /// log, and fails the run on any other host).
    private static func probeOfflineTrap() async {
        guard ProcessInfo.processInfo.environment[proxyTrapVariable] != nil else { return }
        let probe = OfflineProbe()
        let loaded = await probe.load(URL(string: "https://example.com/thuban-offline-probe")!)
        if loaded {
            fputs("smoke: FAIL offline probe: a WebKit load reached the network\n", stderr)
        } else {
            print("smoke: offline probe blocked")
        }
    }

    /// One throwaway web view that reports whether a load finished.
    @MainActor
    private final class OfflineProbe: NSObject, WKNavigationDelegate {
        private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        private var continuation: CheckedContinuation<Bool, Never>?

        func load(_ url: URL) async -> Bool {
            webView.navigationDelegate = self
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.load(URLRequest(url: url, timeoutInterval: 15))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    self?.finish(false)
                }
            }
        }

        private func finish(_ loaded: Bool) {
            continuation?.resume(returning: loaded)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }

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
        try await seedEquationSheet(store: store, classId: classId)
        try await store.set(.lastClass, classId)
    }

    /// A small hand-made sheet for the sample class: three groups, one entry a named list of two equations.
    private static func seedEquationSheet(store: Store, classId: ClassID) async throws {
        let sheet: [(group: String, entries: [(name: String, equations: [String], note: String?)])] = [
            ("Partial derivatives", [
                ("Chain rule", ["\\frac{\\mathrm{d}z}{\\mathrm{d}t} = \\frac{\\partial z}{\\partial x}\\frac{\\mathrm{d}x}{\\mathrm{d}t} + \\frac{\\partial z}{\\partial y}\\frac{\\mathrm{d}y}{\\mathrm{d}t}"], "z = f(x, y) with x and y functions of t"),
                ("Clairaut's theorem", ["f_{xy}(a, b) = f_{yx}(a, b)"], "when both mixed partials are continuous near (a, b)"),
                ("Implicit differentiation", ["\\frac{\\partial z}{\\partial x} = -\\frac{F_x}{F_z}", "\\frac{\\partial z}{\\partial y} = -\\frac{F_y}{F_z}"], "for F(x, y, z) = 0 with ∂F/∂z ≠ 0"),
            ]),
            ("Tangent planes", [
                ("Tangent plane", ["z - z_0 = f_x(x_0, y_0)(x - x_0) + f_y(x_0, y_0)(y - y_0)"], nil),
                ("Linear approximation", ["f(x, y) \\approx f(a, b) + f_x(a, b)(x - a) + f_y(a, b)(y - b)"], "good near (a, b)"),
                ("Total differential", ["\\mathrm{d}z = f_x\\,\\mathrm{d}x + f_y\\,\\mathrm{d}y"], nil),
            ]),
            ("Vectors", [
                ("Dot product", ["\\vec{a}\\,\\cdot\\,\\vec{b} = a_1b_1 + a_2b_2 + a_3b_3", "\\vec{a}\\,\\cdot\\,\\vec{b} = \\lVert\\vec{a}\\rVert\\,\\lVert\\vec{b}\\rVert\\cos\\theta"], nil),
                ("Gradient", ["\\nabla f(x, y) = \\langle f_x(x, y), f_y(x, y)\\rangle"], nil),
                ("Directional derivative", ["D_{\\vec{u}}f = \\nabla f\\cdot\\vec{u}"], "u a unit vector; largest along ∇f"),
                ("Cross product", ["\\left\\lVert\\vec{a}\\times\\vec{b}\\right\\rVert = \\lVert\\vec{a}\\rVert\\,\\lVert\\vec{b}\\rVert\\sin\\theta"], nil),
            ]),
        ]
        for section in sheet {
            let group = try await store.addEquationGroup(named: section.group, to: classId)
            for entry in section.entries {
                try await store.addEquationEntry(
                    EquationEntry(groupId: group.id, name: entry.name, equations: entry.equations, note: entry.note), at: nil
                )
            }
        }
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
            await waitUntil(timeout: 3) { session.currentInstance != nil }
            print("smoke: opened on \(session.currentQuestion?.sourceRef ?? "none") seed \(session.currentInstance?.seed ?? "-") inputs \(session.inputs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) filter \(session.isStudyFiltered)")
            // THUBAN_SMOKE_COMPOSER: a draft (with $…$ math) in the tutor composer, captured.
            if let draft = ProcessInfo.processInfo.environment["THUBAN_SMOKE_COMPOSER"], !draft.isEmpty {
                session.studyState.composerText = draft
                session.studyState.composer.setText(draft)
                await sleep(3)
                _ = try await capture(window: window, name: "composer", in: directory)
            }
            // THUBAN_SMOKE_STUDY_TYPE: study only this type (the Filter dropdown), then capture the first question.
            if let type = ProcessInfo.processInfo.environment["THUBAN_SMOKE_STUDY_TYPE"], !type.isEmpty {
                await session.setStudyFilter(QuestionFilter(types: [type]))
                print("smoke: filter type=\(type) → \(session.questionCount) of \(session.unfilteredQuestions.count); first: \(session.currentQuestion?.sourceRef ?? "none") [\(session.currentQuestion?.type ?? "")]")
                await sleep(4)
                _ = try await capture(window: window, name: "filtered", in: directory)
            }
            for (offset, match) in matches.enumerated() {
                guard let question = session.questions.first(where: { ($0.sourceRef ?? "").localizedCaseInsensitiveContains(match) }) else {
                    fputs("smoke: no question matches \(match)\n", stderr)
                    continue
                }
                await session.study(question: question)
                await waitUntil(timeout: 10) { session.currentQuestion?.id == question.id && session.currentInstance != nil }
                await sleep(4)
                // THUBAN_SMOKE_TYPE="a|<latex>": put an answer into a part (as the calculator's "copy to answer" does).
                if let typed = ProcessInfo.processInfo.environment["THUBAN_SMOKE_TYPE"], let bar = typed.firstIndex(of: "|") {
                    session.studyState.form.focus(partId: String(typed[..<bar]))
                    await sleep(0.5)
                    session.studyState.form.insert(latex: String(typed[typed.index(after: bar)...]))
                    await sleep(1.5)
                }
                // THUBAN_SMOKE_INPUT="a|<value>": set a part's stored answer directly (a diagram's JSON) and redraw the form.
                if let raw = ProcessInfo.processInfo.environment["THUBAN_SMOKE_INPUT"], let bar = raw.firstIndex(of: "|"),
                   let instance = session.currentInstance {
                    session.inputs[String(raw[..<bar])] = String(raw[raw.index(after: bar)...])
                    session.studyState.form.load(instance: instance, inputs: session.inputs, verdicts: session.verdicts,
                                                 choiceImages: session.studyState.choiceImages)
                    await sleep(1.5)
                }
                // THUBAN_SMOKE_CHECK=1: press Check answers so the results sheet is captured with the popovers below.
                if ProcessInfo.processInfo.environment["THUBAN_SMOKE_CHECK"] == "1" {
                    await session.checkAnswers()
                    await sleep(1.5)
                }
                _ = try await capture(window: window, name: String(format: "q%02d-top", offset + 1), in: directory)
                // Popovers (an open dropdown) are windows of their own.
                for (index, other) in NSApp.windows.enumerated() where other !== window && other.isVisible && other.frame.width > 40 {
                    _ = try? await capture(window: other, name: String(format: "q%02d-window%d", offset + 1, index), in: directory)
                }
                // Every native scroll view to its end (the question pane is not always the first one).
                let scrolls = window.contentView.map(allScrollViews(in:)) ?? []
                if !scrolls.isEmpty {
                    for scroll in scrolls {
                        let flipped = scroll.documentView?.isFlipped ?? true
                        // THUBAN_SMOKE_SCROLL=0.4: scroll to that fraction of the way down instead of the end.
                        let fraction = ProcessInfo.processInfo.environment["THUBAN_SMOKE_SCROLL"].flatMap(Double.init) ?? 1
                        let end = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height) * fraction
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? end : 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
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

    private static func allScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView, scroll.documentView != nil, !(String(describing: type(of: scroll)).contains("WK")) { found.append(scroll) }
        for child in view.subviews { found += allScrollViews(in: child) }
        return found
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
            await probeOfflineTrap()

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

            // 02 — The graph pane on the Thuban Graph engine. The brief's 2D example: the student's rational function
            // with its asymptotes, a labelled line and a point added by the tutor through the real tool path.
            session.graphMode = .twoD
            // A roomier window for the graph scenes (the pane gets what the question and tutor leave).
            let standardFrame = window.frame
            window.setFrame(NSRect(x: standardFrame.minX, y: standardFrame.maxY - 940, width: 1560, height: 940), display: true)
            session.showGraph = true
            let host = session.graphHost
            let standardGraphWidth = state.graphWidth
            state.graphWidth = 700
            host.listPreference = true   // the expression list beside the graph (a narrow pane starts without it)
            await app.graphEngine.waitUntilWarm()
            if let error = app.graphEngine.startupError { fputs("smoke: FAIL graph engine: \(error)\n", stderr) }
            host.typeIntoBlankRow("f(x)=\\frac{2x^2+1}{x^2-4}", mode: .twoD)
            // 02c — the tutor's replay (tool calls exactly as the tutor sends them), captured with its chip showing.
            let replay: [(String, JSONValue)] = [
                (TutorTools.showGraph, ["mode": "2d"]),
                (TutorTools.graphAddExpression, ["id": "va1", "latex": "x=-2", "dashed": true]),
                (TutorTools.graphAddExpression, ["id": "va2", "latex": "x=2", "dashed": true]),
                (TutorTools.graphAddExpression, ["id": "ha", "latex": "y=2", "dashed": true, "label": "y=2"]),
                (TutorTools.graphAddExpression, ["id": "pt", "latex": "\\left(0,-0.25\\right)", "label": "(0, -0.25)"]),
                (TutorTools.graphSetViewport, ["xmin": -8, "xmax": 8, "ymin": -6, "ymax": 8]),
            ]
            for (name, input) in replay {
                let reply = await session.handleTutorTool(name: name, input: input)
                print("smoke: tool \(name) → \(reply.jsonString())")
                if reply["error"] != nil || reply["warnings"] != nil { fputs("smoke: FAIL tool \(name): \(reply.jsonString())\n", stderr) }
            }
            await host.analyzeNow()
            await sleep(2)
            print("smoke: graph rows \(host.rows.map { "\($0.mode.rawValue):\($0.id)\($0.fromTutor ? "*" : "")" })")
            written.append(try await captureGraph(window: window, name: "02c-study-graph-tutor", in: directory))
            // The chip goes after 5 s: the plain pane.
            await waitUntil(timeout: 8) { !host.tutorEditedRecently }
            await sleep(1)
            host.listPreference = nil
            await sleep(1)
            written.append(try await captureGraph(window: window, name: "02-study-graph", in: directory))

            // 02e — a slider row and a derivative row (the tutor's), a timed slider drag, then the rows go again.
            let sliderRows: [JSONValue] = [
                ["id": "a", "latex": "a=1"],
                ["id": "par", "latex": "y=a\\left(x-1\\right)^2-3"],
                ["id": "fp", "latex": "y=f'(x)", "color": "violet"],
            ]
            for input in sliderRows {
                let reply = await session.handleTutorTool(name: TutorTools.graphAddExpression, input: input)
                print("smoke: tool graph_add_expression (slider scene) → \(reply.jsonString())")
                if reply["error"] != nil || reply["warnings"] != nil { fputs("smoke: FAIL slider scene: \(reply.jsonString())\n", stderr) }
            }
            await host.analyzeNow()
            let dragValues = (0 ..< 40).map { 1 + 2 * Double($0) / 39 }
            if let timing = await host.timeSliderDrag(id: "a", values: dragValues) {
                print("smoke: perf slider drag: \(timing)")
                if timing.meanMilliseconds > 50 { fputs("smoke: FAIL slider drag too slow: \(timing)\n", stderr) }
            } else {
                fputs("smoke: FAIL slider row a has no slider\n", stderr)
            }
            await sleep(1.5)
            written.append(try await captureGraph(window: window, name: "02e-study-graph-slider-derivative", in: directory))
            for id in ["a", "par", "fp"] {
                _ = await session.handleTutorTool(name: TutorTools.graphRemoveExpression, input: ["id": .string(id)])
            }

            // 02b — 3D: its own rows and camera. A surface typed by the student, a space curve added by the tutor.
            session.graphMode = .threeD
            host.typeIntoBlankRow("z=\\sin(x)\\cos(y)", mode: .threeD)
            let curve = await session.handleTutorTool(name: TutorTools.graphAddExpression,
                                                      input: ["id": "helix", "latex": "\\left(2\\cos t,2\\sin t,\\frac{t}{3}\\right)"])
            print("smoke: tool graph_add_expression (3D) → \(curve.jsonString())")
            await host.analyzeNow()
            await sleep(3)
            written.append(try await captureGraph(window: window, name: "02b-study-graph-3d", in: directory))
            let orbit = await host.timeOrbit(steps: 60, degrees: 3)
            print("smoke: perf 3D orbit: \(orbit)")
            if orbit.meanMilliseconds > 50 { fputs("smoke: FAIL 3D orbit too slow: \(orbit)\n", stderr) }
            host.resetView()
            session.graphMode = .twoD
            // 02d — the standard window: a narrow pane starts with the list hidden, the graph keeps the room.
            state.graphWidth = standardGraphWidth
            window.setFrame(standardFrame, display: true)
            await sleep(2)
            written.append(try await captureGraph(window: window, name: "02d-study-graph-narrow", in: directory))

            // 03 — Calculator overlay (the engine's Scientific calculator, with Insert) and the virtual keyboard.
            session.showCalculator = true
            session.showKeyboard = true
            for latex in ["\\frac{3}{4}+\\frac{1}{6}", "\\sqrt{2}\\cdot 3", "\\sin\\left(\\frac{\\pi}{6}\\right)"] {
                let result = await host.submitToCalculator(latex)
                print("smoke: calculator \(latex) = \(result ?? "nil")")
            }
            if host.calculatorHistoryCount != 3 { fputs("smoke: FAIL calculator history \(host.calculatorHistoryCount)\n", stderr) }
            await sleep(4)
            if ProcessInfo.processInfo.environment["THUBAN_SMOKE_DEBUG"] != nil, let content = window.contentView {
                for web in subviews(of: content).compactMap({ $0 as? WKWebView }) {
                    let text = (try? await web.evaluateJavaScript("(function(){var s=document.getElementById('sci');var a=document.getElementById('app');return document.readyState+' w='+innerWidth+' h='+innerHeight+' layout='+(a?a.dataset.layout:'-')+' sci='+(s?JSON.stringify(s.getBoundingClientRect()):'-')+' bodyOpacity='+getComputedStyle(document.body).opacity+' app='+(a?JSON.stringify(a.getBoundingClientRect())+getComputedStyle(a).display:'-');})()")) as? String
                    print("smoke: web \(web.url?.absoluteString ?? "-") frame=\(web.frame) → \(text ?? "nil")")
                    if web.url?.path.contains("calc") == true, let image = try? await web.takeSnapshot(configuration: nil),
                       let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: directory.appendingPathComponent("debug-calc-snapshot.png"))
                        print("smoke: web calc hidden=\(web.isHiddenOrHasHiddenAncestor) alpha=\(web.alphaValue) layer=\(String(describing: web.layer?.isHidden)) superviews=\(sequence(first: web as NSView, next: { $0.superview }).map { "\(type(of: $0))[\($0.alphaValue)]" }.prefix(6).joined(separator: " < "))")
                    }
                }
            }
            // The calculator and keyboard pages must have painted before the capture (the window server's capture can
            // miss a web view that has not): wait for both, then check the capture, falling back to the composite.
            let pages = { (content: NSView?) -> [WKWebView] in
                guard let content else { return [] }
                return subviews(of: content).compactMap { $0 as? WKWebView }.filter {
                    let url = $0.url?.absoluteString ?? ""
                    return url.contains("calc") || url.contains("question")   // the keyboard is part of the form page
                }
            }
            var painted = false
            for _ in 0 ..< 30 {
                let views = pages(window.contentView)
                var all = views.count >= 2
                for view in views where all { all = await isPainted(view) }
                if all { painted = true; break }
                await sleep(0.3)
            }
            if !painted {
                let urls = pages(window.contentView).map { $0.url?.lastPathComponent ?? "-" }
                fputs("smoke: FAIL calculator or question/keyboard page never painted (found \(urls))\n", stderr)
            }
            let calcShot = try await captureGraph(window: window, name: "03-study-keyboard-calc", in: directory)
            if let calcView = pages(window.contentView).first(where: { $0.url?.absoluteString.contains("calc") == true }),
               captureIsBlank(calcShot, over: calcView, in: window) {
                print("smoke: 03: calculator blank in the window-server capture; using the composite")
                written.append(try await capture(window: window, name: "03-study-keyboard-calc", in: directory))
            } else {
                written.append(calcShot)
            }

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
            await sleep(4)   // the review pane draws the chart natively
            written.append(try await capture(window: window, name: "05b-figure-field", in: directory))
            session.section = .questionBank
            await sleep(0.5)
            session.section = .importDocs
            session.pendingFigureReviewIndex = 1
            session.pendingFigureReview = session.importQueue.first?.id
            await sleep(4)
            written.append(try await capture(window: window, name: "05c-figure-curve", in: directory))
            session.section = .questionBank
            await sleep(0.5)

            // 05d–05f — The equation sheet, its entry editor, and the read-only panel beside a question.
            let equations = session.equations
            session.section = .equations
            await waitUntil(timeout: 6) { equations.isLoaded && equations.sheetPage.isPageReady }
            await sleep(2)
            written.append(try await capture(window: window, name: "05d-equations", in: directory))

            // 05g — The empty state (shown with the sheet cleared in memory only, then restored).
            let seeded = equations.sheet
            equations.setSheet(EquationSheet(classId: seeded.classId))
            await sleep(1)
            written.append(try await capture(window: window, name: "05g-equations-empty", in: directory))
            equations.setSheet(seeded)
            await sleep(1)

            if let list = equations.sheet.sections.first?.entries.first(where: { $0.isList }) {
                equations.editing = EquationEntryDraft(editing: list)
                let sheetWindow = try await waitForWindow(timeout: 5) { $0.sheetParent === window && $0.isVisible }
                await sleep(3)
                // The window server's own pixels: a web snapshot leaves MathLive fields in a sheet blank.
                let file = directory.appendingPathComponent("05e-equation-editor.png")
                let screen = Process()
                screen.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                screen.arguments = ["-x", "-o", "-l", String(sheetWindow.windowNumber), file.path]
                try screen.run()
                screen.waitUntilExit()
                written.append(file)
                equations.editing = nil
                await sleep(1)
            }

            session.section = .study
            let graphWasOpen = session.showGraph
            session.showGraph = false
            session.showEquations = true
            await waitUntil(timeout: 6) { equations.panelPage.isPageReady }
            await sleep(2.5)
            written.append(try await capture(window: window, name: "05f-study-equations", in: directory))
            session.showEquations = false
            session.showGraph = graphWasOpen
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
            window.setFrame(NSRect(x: standardFrame.minX, y: standardFrame.maxY - 940, width: 1560, height: 940), display: true)
            window.makeKeyAndOrderFront(nil)
            state.graphWidth = 700
            host.listPreference = true
            await sleep(6)   // a theme change is an environment update: the graph re-tints without a reload
            written.append(try await capture(window: window, name: "07-study-dark-cobalt", in: directory))   // composited: see captureGraph

            // 07b — the 3D graph in the dark scheme.
            session.graphMode = .threeD
            await sleep(3)
            written.append(try await captureGraph(window: window, name: "07b-study-graph-3d-dark", in: directory))
            session.graphMode = .twoD
            host.listPreference = nil
            state.graphWidth = standardGraphWidth
            window.setFrame(standardFrame, display: true)

            // 08 — The equation sheet in the dark scheme.
            session.section = .equations
            await sleep(3)
            written.append(try await capture(window: window, name: "08-equations-dark", in: directory))

            for url in written { print("smoke: wrote \(url.path)") }
            print("smoke: done")
        } catch {
            logger.error("smoke failed: \(error.localizedDescription, privacy: .public)")
            fputs("smoke: FAILED: \(error.localizedDescription)\n", stderr)
        }
        NSApp.terminate(nil)
    }

    /// Graph scenes: the window server's own pixels (`screencapture -l`), which include the Metal 3D view that
    /// `cacheDisplay` cannot read; falls back to the composited capture when that is unavailable. Once the Settings
    /// window has covered the main window, WebKit views come out blank in window-server captures (they are fine in
    /// their own snapshots), so the later 2D scene (07) uses the composited capture.
    private static func captureGraph(window: NSWindow, name: String, in directory: URL) async throws -> URL {
        let file = directory.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: file)
        let screen = Process()
        screen.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screen.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        do {
            try screen.run()
            screen.waitUntilExit()
        } catch {
            logger.error("screencapture failed: \(error.localizedDescription, privacy: .public)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if screen.terminationStatus == 0, size > 20_000 {
            print("smoke: \(name): window server capture")
            if ProcessInfo.processInfo.environment["THUBAN_SMOKE_DEBUG"] != nil {
                _ = try? await capture(window: window, name: "\(name)-composite", in: directory)
            }
            return file
        }
        return try await capture(window: window, name: name, in: directory)
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

    /// The web view's own snapshot shows more than one flat colour (its page has painted).
    private static func isPainted(_ webView: WKWebView) async -> Bool {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        let bounds = NSRect(origin: .zero, size: rep.size)
        return !isBlank(rep, region: bounds, bounds: bounds, scale: rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1)
    }

    /// The window-server capture at `file` is one flat colour where `webView` sits.
    private static func captureIsBlank(_ file: URL, over webView: WKWebView, in window: NSWindow) -> Bool {
        guard let data = try? Data(contentsOf: file), let rep = NSBitmapImageRep(data: data) else { return false }
        // `screencapture -l` covers the whole window frame (window coordinates, origin bottom left).
        let frame = window.frame
        let rect = webView.convert(webView.visibleRect, to: nil).insetBy(dx: 12, dy: 12)
        let scale = CGFloat(rep.pixelsWide) / frame.width
        return isBlank(rep, region: rect, bounds: NSRect(origin: .zero, size: frame.size), scale: scale)
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
