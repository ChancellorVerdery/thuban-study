import Foundation
import XCTest
@testable import ThubanCore

final class ModelsTests: XCTestCase {

    // MARK: Helpers

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let back = try decoder.decode(T.self, from: data)
        XCTAssertEqual(back, value, file: file, line: line)
        return back
    }

    /// Whole seconds so ISO 8601 round-trips exactly.
    private let fixedDate = Date(timeIntervalSince1970: 1_758_000_000)

    private func sampleTemplateQuestion(classId: ClassID) -> Question {
        let template = MathTemplate(
            params: [
                TemplateParam(name: "a", kind: .int(min: 1, max: 9), exclude: [0]),
                TemplateParam(name: "b", kind: .real(min: 0.5, max: 4, decimals: 1)),
                TemplateParam(name: "v", kind: .choice(["x", "t"])),
            ],
            constraints: ["a \\ne b"],
            stem: "Let $f({v}) = {a}{v}^2 + {b}$.",
            parts: [
                TemplatePart(
                    id: "a",
                    prompt: "Find $f'({v})$.",
                    answerExpr: "2a v",
                    conditions: AnswerConditions(simplified: true)
                ),
                TemplatePart(
                    id: "b",
                    prompt: "Evaluate $f(1)$ to two decimals.",
                    answerExpr: "a + b",
                    answerKind: .numeric,
                    conditions: AnswerConditions(roundingDecimals: 2)
                ),
            ],
            seedNote: "Coefficient and constant vary."
        )
        return Question(
            id: QuestionID(raw: "q-1"),
            classId: classId,
            documentId: DocumentID(raw: "d-1"),
            sourceRef: "Homework 4 · Q3",
            kind: .mathTemplate,
            stem: "Let $f(x) = 3x^2 + 1$.",
            parts: [
                QuestionPart(id: "a", prompt: "Find $f'(x)$.", answerKind: .math, answer: AnswerSpec(latex: "6x"),
                             conditions: AnswerConditions(simplified: true)),
                QuestionPart(id: "b", prompt: "Evaluate $f(1)$.", answerKind: .numeric, answer: AnswerSpec(latex: "4"),
                             conditions: AnswerConditions(roundingDecimals: 2)),
            ],
            template: template,
            figureIds: [FigureID(raw: "f-1")],
            tags: ["derivatives"],
            difficulty: 2,
            createdAt: fixedDate
        )
    }

    // MARK: Identifiers

    func testIdentifiersEncodeAsBareStrings() throws {
        let id = QuestionID(raw: "abc-123")
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"abc-123\"")
        let back = try JSONDecoder().decode(QuestionID.self, from: data)
        XCTAssertEqual(back, id)
        XCTAssertEqual(back.description, "abc-123")

        let wrapped = try JSONEncoder().encode(["id": ClassID(raw: "c1")])
        XCTAssertEqual(String(data: wrapped, encoding: .utf8), "{\"id\":\"c1\"}")

        let fresh = ClassID.new()
        XCTAssertNotNil(UUID(uuidString: fresh.raw))
        XCTAssertNotEqual(ClassID.new(), ClassID.new())
    }

    // MARK: Round-trips

    func testQuestionWithTemplateRoundTrips() throws {
        let question = sampleTemplateQuestion(classId: ClassID(raw: "c-1"))
        let back = try roundTrip(question)
        XCTAssertEqual(back.template?.params.count, 3)
        XCTAssertEqual(back.template?.params[2].kind, .choice(["x", "t"]))
        XCTAssertEqual(back.parts[1].conditions.roundingDecimals, 2)
        XCTAssertFalse(back.parts[1].conditions.exactRadicals)
    }

    func testTemplateParamKindUsesTypeDiscriminator() throws {
        let param = TemplateParam(name: "a", kind: .real(min: 0, max: 1, decimals: 3))
        let data = try JSONEncoder().encode(param)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kind = try XCTUnwrap(json["kind"] as? [String: Any])
        XCTAssertEqual(kind["type"] as? String, "real")
        XCTAssertEqual(kind["decimals"] as? Int, 3)

        // Agent-written JSON may omit `exclude` and rely on defaults inside `kind`.
        let lenient = Data("""
        {"name":"n","kind":{"type":"int"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(TemplateParam.self, from: lenient)
        XCTAssertEqual(decoded.kind, .int(min: 1, max: 9))
        XCTAssertEqual(decoded.exclude, [])
    }

    func testFigureRoundTrips() throws {
        let figure = Figure(
            id: FigureID(raw: "fig-1"),
            documentId: DocumentID(raw: "d-1"),
            pageOrIndex: 4,
            originalPath: "d-1/4.png",
            kind: .chart,
            chart: StandardChart(
                chartType: "line",
                xLabel: "t (s)",
                yLabel: "v (m/s)",
                series: [
                    ChartSeries(name: "measured", points: [[0, 0], [1, 2.5], [2, 5]]),
                    ChartSeries(name: "model", latex: "2.5x", color: "#ff8800"),
                ],
                xRange: [0, 2],
                yRange: [0, 6],
                confidence: 0.87
            ),
            status: .reviewing,
            caption: "Velocity over time"
        )
        let back = try roundTrip(figure)
        XCTAssertEqual(back.chart?.series[0].points?[1], [1, 2.5])
        XCTAssertEqual(back.chart?.series[1].latex, "2.5x")
    }

    func testStandardChartClampsConfidence() throws {
        for (raw, expected) in [("1e307", 1.0), ("-2", 0.0), ("0.42", 0.42), ("7", 1.0)] {
            let json = Data("{\"chartType\":\"line\",\"series\":[],\"confidence\":\(raw)}".utf8)
            let chart = try JSONDecoder().decode(StandardChart.self, from: json)
            XCTAssertEqual(chart.confidence, expected, raw)
        }
        XCTAssertEqual(StandardChart(chartType: "line", confidence: .infinity).confidence, 0)
        XCTAssertEqual(StandardChart(chartType: "line", confidence: .nan).confidence, 0)
        XCTAssertEqual(StandardChart.clampedConfidence(1e307), 1)
    }

    func testTutorMessageRoundTrips() throws {
        let message = TutorMessage(
            id: MessageID(raw: "m-1"),
            classId: ClassID(raw: "c-1"),
            questionId: QuestionID(raw: "q-1"),
            role: .tutor,
            content: "What happens to $x^2$ when $x$ doubles?",
            toolEvents: [
                ToolEvent(id: "toolu_1", name: "graph_add_expression", summary: "Added y = x^2",
                          input: ["id": "e1", "latex": "y=x^2", "dashed": true, "weight": 1.5]),
                ToolEvent(id: "toolu_2", name: "show_graph", summary: "Showed the graph"),
            ],
            solutionRequested: false,
            createdAt: fixedDate
        )
        let back = try roundTrip(message)
        XCTAssertEqual(back.toolEvents[0].input?["latex"]?.stringValue, "y=x^2")
        XCTAssertEqual(back.toolEvents[0].input?["dashed"]?.boolValue, true)
        XCTAssertNil(back.toolEvents[1].input)
    }

    func testAttemptRoundTrips() throws {
        let attempt = Attempt(
            id: AttemptID(raw: "a-1"),
            questionId: QuestionID(raw: "q-1"),
            seed: "1a2b3c4d",
            responses: ["a": "6x", "b": "0.6247"],
            verdicts: [
                "a": Verdict(outcome: .correct, message: "Correct.", canonicalStudent: "6x", canonicalExpected: "6x"),
                "b": Verdict(outcome: .equivalentButConditionFailed,
                             message: "Equivalent, but this part requires an exact form.",
                             failedConditions: ["exactForm"]),
            ],
            score: 0.5,
            createdAt: fixedDate
        )
        let back = try roundTrip(attempt)
        XCTAssertEqual(back.verdicts["b"]?.failedConditions, ["exactForm"])
        XCTAssertFalse(back.isFullyCorrect)

        let progress = QuestionProgress(questionId: QuestionID(raw: "q-1"), status: .learning, streak: 1,
                                        lastAttemptAt: fixedDate, lastScore: 0.5)
        _ = try roundTrip(progress)
    }

    func testStudyClassAndDocumentRoundTrip() throws {
        let cls = StudyClass(id: ClassID(raw: "c-1"), name: "Calculus II", courseCode: "MATH 152", term: "Fall 2026",
                             tint: "#c9a227", tutorStyle: .directHints, sortOrder: 1, createdAt: fixedDate)
        _ = try roundTrip(cls)

        let doc = ImportedDocument(id: DocumentID(raw: "d-1"), classId: cls.id, filename: "hw4.pdf", kind: .pdf,
                                   storedPath: "d-1/hw4.pdf", byteCount: 1234, importedAt: fixedDate,
                                   status: .generating, statusDetail: "Reading pages 4–9 of 22",
                                   modelUsed: ClaudeModel.sonnet.rawValue, classification: .existingQuestions,
                                   questionCount: 3, figureCount: 1)
        _ = try roundTrip(doc)

        // Minimal JSON (as the store might have from an older version) still decodes.
        let minimal = Data("""
        {"id":"c-2","name":"Physics"}
        """.utf8)
        let decoded = try JSONDecoder().decode(StudyClass.self, from: minimal)
        XCTAssertEqual(decoded.tutorStyle, .socratic)
        XCTAssertEqual(decoded.sortOrder, 0)
    }

    func testModelPolicyRoundTripAndEscalation() throws {
        let policy = ModelPolicy(defaultModel: .sonnet, allowEscalation: true, pinned: nil)
        _ = try roundTrip(policy)
        XCTAssertEqual(policy.escalationModel, .opus)
        XCTAssertNil(ModelPolicy(defaultModel: .sonnet, allowEscalation: true, pinned: .sonnet).escalationModel)
        XCTAssertNil(ModelPolicy(defaultModel: .opus).escalationModel)
        XCTAssertEqual(ClaudeModel.opus.rawValue, "claude-opus-5")
        XCTAssertEqual(ClaudeModel.haiku.rawValue, "claude-haiku-4-5-20251001")
        XCTAssertEqual(ClaudeModel.sonnet.displayName, "Claude Sonnet")
        XCTAssertFalse(TutorStyle.exam.promptHint.isEmpty)
    }

    // MARK: JSONValue

    func testJSONValueFoundationRoundTrip() throws {
        let text = """
        {"name":"Thuban","ok":true,"nope":false,"n":42,"pi":3.14159,"none":null,"list":[1,"two",{"three":3}],"nested":{"a":{"b":[]}}}
        """
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let value = try XCTUnwrap(JSONValue(any: object))

        XCTAssertEqual(value["name"]?.stringValue, "Thuban")
        XCTAssertEqual(value["ok"]?.boolValue, true)
        XCTAssertEqual(value["nope"]?.boolValue, false)
        XCTAssertEqual(value["n"]?.doubleValue, 42)
        XCTAssertEqual(value["n"]?.intValue, 42)
        XCTAssertEqual(value["pi"]?.doubleValue ?? 0, 3.14159, accuracy: 1e-12)
        XCTAssertEqual(value["none"], .null)
        XCTAssertEqual(value["list"]?[1]?.stringValue, "two")
        XCTAssertEqual(value["list"]?[2]?["three"]?.intValue, 3)
        XCTAssertEqual(value["nested"]?["a"]?["b"]?.arrayValue, [])
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["list"]?[99])

        // Booleans stay booleans and numbers stay numbers through Foundation and back.
        let foundation = value.foundationObject
        let again = try XCTUnwrap(JSONValue(any: foundation))
        XCTAssertEqual(again, value)
        let dict = try XCTUnwrap(foundation as? [String: Any])
        XCTAssertTrue(dict["ok"] is Bool)
        XCTAssertTrue(dict["none"] is NSNull)

        // Codable round-trip and literals.
        let literal: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        let data = try JSONEncoder().encode(literal)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), literal)
        XCTAssertEqual(literal["a"]?[4], .null)
        XCTAssertNil(JSONValue(any: Date()))
    }

    // MARK: AnswerConditions

    func testAnswerConditionsSummary() {
        XCTAssertEqual(AnswerConditions.none.summary, "Exact form required")
        XCTAssertTrue(AnswerConditions.none.isDefault)
        XCTAssertTrue(AnswerConditions.none.exactRadicals)
        XCTAssertTrue(AnswerConditions.none.implicitAllowed)

        let rationalized = AnswerConditions(rationalizedDenominator: true)
        XCTAssertEqual(rationalized.summary, "Exact form required · Rationalized denominator")

        let rounded = AnswerConditions(roundingDecimals: 3, tolerance: 0.0005, units: "m/s", custom: ["Show your work"])
        XCTAssertEqual(rounded.summary, "Round to 3 decimal places · Tolerance ±0.0005 · Show your work")
        XCTAssertFalse(rounded.exactRadicals)

        let explicit = AnswerConditions(factored: true, explicit: true)
        XCTAssertFalse(explicit.implicitAllowed)
        XCTAssertEqual(explicit.summary, "Exact form required · Fully factored · Solved explicitly (y = …)")

        let whole = AnswerConditions(roundingDecimals: 0, simplified: true, expanded: true)
        XCTAssertEqual(whole.summary, "Round to the nearest whole number · Simplified form · Expanded form")
    }

    func testAnswerConditionsLenientDecoding() throws {
        let data = Data("""
        {"rationalizedDenominator":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(AnswerConditions.self, from: data)
        XCTAssertEqual(decoded, AnswerConditions(rationalizedDenominator: true))
        XCTAssertEqual(try JSONDecoder().decode(AnswerConditions.self, from: Data("{}".utf8)), .none)
    }

    // MARK: ThubanError

    func testThubanErrorDescriptions() {
        XCTAssertEqual(ThubanError.api(status: 429, message: "slow down").errorDescription,
                       "Claude API error (429): slow down")
        XCTAssertTrue(ThubanError.api(status: 529, message: "").isRetryable)
        XCTAssertFalse(ThubanError.api(status: 401, message: "").isRetryable)
        XCTAssertEqual(ThubanError.invalidTemplate(["a", "b"]).errorDescription,
                       "The question template is invalid: a; b")
        XCTAssertNotNil(ThubanError.notConnected.errorDescription)
        XCTAssertEqual((ThubanError.cancelled as Error).localizedDescription, "Cancelled.")
    }

    // MARK: AppPaths

    func testAppPathsHonorsHomeOverride() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thuban-tests-\(UUID().uuidString)", isDirectory: true)
        setenv(AppPaths.homeOverrideVariable, temp.path, 1)
        defer {
            unsetenv(AppPaths.homeOverrideVariable)
            try? FileManager.default.removeItem(at: temp)
        }

        XCTAssertEqual(AppPaths.baseDirectory.standardizedFileURL.path, temp.standardizedFileURL.path)
        XCTAssertEqual(AppPaths.database.lastPathComponent, "thuban.sqlite")
        XCTAssertEqual(AppPaths.documents.lastPathComponent, "documents")
        XCTAssertEqual(AppPaths.figures.lastPathComponent, "figures")
        XCTAssertEqual(AppPaths.exports.lastPathComponent, "exports")

        try AppPaths.ensureDirectories()
        var isDir: ObjCBool = false
        for url in AppPaths.allDirectories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), url.path)
            XCTAssertTrue(isDir.boolValue)
        }
        XCTAssertEqual(AppPaths.documentURL("d-1/hw.pdf").path, temp.standardizedFileURL.path + "/documents/d-1/hw.pdf")
    }

    func testAppPathsDefaultIsApplicationSupport() {
        unsetenv(AppPaths.homeOverrideVariable)
        let base = AppPaths.baseDirectory
        XCTAssertEqual(base.lastPathComponent, "Thuban Study")
        XCTAssertTrue(base.path.contains("Application Support"), base.path)
    }

    // MARK: SettingsKey

    func testSettingsKeys() {
        XCTAssertEqual(SettingsKey.lastClass.rawValue, "lastClass")
        XCTAssertEqual(SettingsKey.theme, SettingsKey(rawValue: "theme"))
        let all: Set<SettingsKey> = [.lastClass, .theme, .modelPolicy, .tutorMayEditGraph, .windowFrame, .onboardingDone]
        XCTAssertEqual(all.count, 6)
    }
}
