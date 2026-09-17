# Thuban Study — architecture contract

Native macOS app (SwiftUI, macOS 15+, Xcode 26, Swift 6 toolchain in **Swift 5 language mode** to keep concurrency
diagnostics manageable; use `async/await`, `@MainActor` for UI-facing state, `actor`s for engines/clients).
Everything below is a contract: implementers keep the names, signatures and message schemas so modules built in
parallel fit together. Add, do not rename. Design reference: the canvas at
https://claude.ai/artifact/MbqgQgK5BeX9tkoCsXkV9X and the brief in `docs/design-brief.md`.

## Repository layout

```
project.yml                          XcodeGen spec → ThubanStudy.xcodeproj (both committed)
ThubanStudy.xcodeproj
Packages/ThubanCore/                 SwiftPM library, unit-testable with `swift test` (no UI)
  Package.swift                      deps: GRDB.swift, ZIPFoundation, SwiftSoup, CoreXLSX
  Sources/ThubanCore/
    Models/        Domain types (Codable, Sendable, Identifiable)
    Store/         GRDB database, migrations, repositories
    Theme/         Color schemes (values from Atlas), color math, resolved tokens
    MathEngine/    JavaScriptCore bridge to Compute Engine, grading, template generation
    AI/            ClaudeClient (Messages API), OAuth, Keychain, agents (Tutor, Import, Figure)
    Documents/     Parsers → DocumentContent (text blocks, figures), chunking
    Resources/     compute-engine.umd.cjs (Bundle.module)
  Tests/ThubanCoreTests/
ThubanStudy/                         App target (imports ThubanCore)
  App/             ThubanStudyApp.swift, AppModel (root @Observable), windows, menu commands
  Views/           Shell (title bar, class tabs), Study, QuestionBank, Import, Settings, Modals, Components
  Web/             WKWebView hosting: ThubanSchemeHandler (thuban://bundle/…), bridge message plumbing,
                   QuestionFormWebView, GraphWebView, CalculatorWebView, ChatWebView
  Resources/
    web/question/  question.html, question.js, question.css   (MathLive form + virtual keyboard)
    web/graph/     graph.html, graph.js                        (Desmos 2D/3D)
    web/calc/      calc.html, calc.js                          (Desmos scientific + fallback)
    web/chat/      chat.html, chat.js, chat.css                (tutor transcript: marked + MathLive static)
    web/shared/    theme.css (CSS variables set by Swift), bridge.js (postMessage helpers)
    web/vendor/    mathlive/, compute-engine/ (esm + chunks), marked/, dompurify/
    Assets.xcassets, Info.plist, ThubanStudy.entitlements
    Secrets.plist (gitignored; DesmosAPIKey) + Secrets.example.plist
scripts/build.sh   xcodebuild Debug build;  scripts/test.sh  swift test for the package + xcodebuild test
docs/              design-brief.md, atlas-theme.md (color values), this file
```

Web resources are served to WKWebView through a custom scheme `thuban://bundle/<path under Resources/web>` by
`ThubanSchemeHandler` (so ES modules and fonts load without file:// CORS trouble). Remote loads allowed only for
`https://www.desmos.com` (Desmos API script) — Info.plist ATS default is fine (https).

## Domain model (ThubanCore/Models)

```swift
public struct ClassID: Hashable, Codable, Sendable { public let raw: String }        // UUID string; same shape for
public struct DocumentID, QuestionID, FigureID, AttemptID, MessageID …               // every ID type

public struct StudyClass: Codable, Identifiable, Sendable {
  public var id: ClassID; public var name: String; public var courseCode: String?; public var term: String?
  public var tint: String?            // optional hex override for the tab dot; nil = scheme accent
  public var tutorStyle: TutorStyle   // .socratic (default) | .directHints | .exam
  public var sortOrder: Int; public var createdAt: Date
}

public enum DocumentKind: String, Codable, Sendable { case pdf, docx, pptx, xlsx, csv, html, mhtml, markdown, text, image, other }
public enum ImportStatus: String, Codable, Sendable { case queued, reading, extractingFigures, generating, escalated, done, failed }

public struct ImportedDocument: Codable, Identifiable, Sendable {
  public var id: DocumentID; public var classId: ClassID; public var filename: String; public var kind: DocumentKind
  public var storedPath: String       // relative path under AppPaths.documents
  public var byteCount: Int; public var importedAt: Date
  public var status: ImportStatus; public var statusDetail: String?   // e.g. "Reading pages 4–9 of 22"
  public var modelUsed: String?       // "claude-sonnet-5" | "claude-opus-5"
  public var classification: DocumentClassification?   // .existingQuestions | .readingMaterial | .mixed
  public var questionCount: Int; public var figureCount: Int
}

public enum QuestionKind: String, Codable, Sendable { case mathTemplate, shortAnswer, multipleChoice, freeResponse, numeric }
public enum ProgressStatus: String, Codable, Sendable { case new, learning, mastered, needsReview }

/// A question as stored in the bank. `parts` hold the static prompt/answer; math questions additionally carry a
/// `template` that the MathEngine instantiates with fresh numbers.
public struct Question: Codable, Identifiable, Sendable {
  public var id: QuestionID; public var classId: ClassID; public var documentId: DocumentID?
  public var sourceRef: String?        // "Homework 4 · Q3", "§14.4 p. 912"
  public var kind: QuestionKind
  public var stem: String              // Markdown with $…$ / $$…$$ LaTeX
  public var parts: [QuestionPart]     // ≥1
  public var template: MathTemplate?   // present iff kind == .mathTemplate
  public var figureIds: [FigureID]
  public var tags: [String]; public var difficulty: Int   // 1–5
  public var createdAt: Date
}

public struct QuestionPart: Codable, Identifiable, Sendable {
  public var id: String                // "a", "b", …
  public var prompt: String            // Markdown+LaTeX
  public var answerKind: AnswerKind    // .math | .numeric | .text | .choice(options:[String]) | .freeResponse
  public var answer: AnswerSpec        // see grading
  public var choices: [String]?        // for .choice
  public var conditions: AnswerConditions
}

public struct AnswerSpec: Codable, Sendable {
  public var latex: String?            // canonical answer (static questions) or an engine expression for templates
  public var alternatives: [String]    // additional accepted latex forms
  public var text: String?             // for .text / .choice (the correct option text)
  public var rubric: String?           // for .freeResponse (tutor/agent-graded, never auto-graded)
}

/// Grading conditions a question may impose. All false/nil ⇒ "any algebraically equivalent form is accepted".
public struct AnswerConditions: Codable, Sendable, Equatable {
  public var roundingDecimals: Int?          // nil ⇒ exact form required (decimals only if exactly equal, e.g. 0.5 == 1/2)
  public var tolerance: Double?              // absolute tolerance when rounding allowed
  public var rationalizedDenominator: Bool   // no radicals in any denominator
  public var simplified: Bool                // must be in simplified form
  public var factored: Bool                  // must be fully factored
  public var expanded: Bool                  // must be expanded (no parentheses products)
  public var explicit: Bool                  // equation must be solved for the dependent variable (y = …)
  public var implicitAllowed: Bool           // implicit equations accepted (default true unless explicit)
  public var exactRadicals: Bool             // radicals must stay symbolic (default when roundingDecimals == nil)
  public var units: String?                  // required unit text, if any
  public var custom: [String]                // free-text conditions the import agent could not map (shown to student, checked by tutor)
}

/// Math-engine template. `params` are sampled, `constraints` filtered, then every `{name}` in stem/prompts/answers is
/// substituted and answer expressions are evaluated by the engine.
public struct MathTemplate: Codable, Sendable {
  public var params: [TemplateParam]         // name, kind (.int(min,max) | .real(min,max,decimals) | .choice([String])), exclude: [Double]
  public var constraints: [String]           // engine boolean expressions in LaTeX with params, e.g. "a \\ne b", "a^2 - 4b > 0"
  public var stem: String                    // with {a}, {b} placeholders
  public var parts: [TemplatePart]           // id, prompt (with placeholders), answerExpr (LaTeX, engine-evaluated), conditions
  public var seedNote: String?               // agent's note on what varies
}

public struct QuestionInstance: Codable, Sendable {   // what the student sees
  public var questionId: QuestionID; public var seed: String   // 8 hex chars
  public var stem: String; public var parts: [InstancePart]     // prompt + resolved answer (kept in memory, never shown)
  public var params: [String: String]
}

public struct Figure: Codable, Identifiable, Sendable {
  public var id: FigureID; public var documentId: DocumentID; public var pageOrIndex: Int
  public var originalPath: String                  // PNG under AppPaths.figures
  public var kind: FigureKind                      // .chart, .diagram, .photo, .table, .unknown
  public var chart: StandardChart?                 // filled by FigureAgent for charts
  public var status: FigureStatus                  // .pending, .reviewing, .accepted, .keptOriginal, .skipped
  public var caption: String?
}

/// Standardized chart: everything needed to redraw the figure in the app's own graph style (Desmos expressions or
/// a table of series). This is the "one graph style across the app" representation.
public struct StandardChart: Codable, Sendable {
  public var chartType: String                     // "line" | "scatter" | "bar" | "function" | "histogram"
  public var xLabel: String?; public var yLabel: String?
  public var series: [ChartSeries]                 // name, points [[x,y]] OR latex (a function of x)
  public var xRange: [Double]?; public var yRange: [Double]?
  public var confidence: Double                    // 0–1 from the agent
}

public struct Attempt: Codable, Identifiable, Sendable {
  public var id: AttemptID; public var questionId: QuestionID; public var seed: String
  public var responses: [String: String]           // partId → latex/text
  public var verdicts: [String: Verdict]           // partId → verdict
  public var score: Double; public var createdAt: Date
}

public struct QuestionProgress: Codable, Sendable { public var questionId: QuestionID; public var status: ProgressStatus; public var streak: Int; public var lastAttemptAt: Date?; public var lastScore: Double? }

public enum ChatRole: String, Codable, Sendable { case student, tutor, system }
public struct TutorMessage: Codable, Identifiable, Sendable {
  public var id: MessageID; public var classId: ClassID; public var questionId: QuestionID?
  public var role: ChatRole; public var content: String          // Markdown + LaTeX
  public var toolEvents: [ToolEvent]                              // graph edits etc. shown as system lines
  public var solutionRequested: Bool                              // student explicitly asked for the solution
  public var createdAt: Date
}
```

## Store (ThubanCore/Store) — GRDB

`public final class Store: Sendable` opened at `AppPaths.database` (`~/Library/Application Support/Thuban Study/thuban.sqlite`).
`AppPaths` also exposes `documents/`, `figures/`, `exports/`. Migrations via `DatabaseMigrator` ("v1"). Tables mirror
the model structs (JSON columns for nested arrays: parts, template, verdicts, toolEvents, chart).

Repositories (all `async throws`, all return value types):
```swift
public protocol ClassRepository { func allClasses() async throws -> [StudyClass]; func insert(_:) ; func update(_:); func delete(_ id: ClassID, deleteFiles: Bool) }
public protocol DocumentRepository { func documents(in: ClassID); func insert; func update(status:detail:model:for:); func delete }
public protocol QuestionRepository { func questions(in: ClassID, filter: QuestionFilter?) ; func insert([Question]); func update; func delete; func question(id:) }
public protocol FigureRepository { func figures(for: DocumentID); func insert; func update }
public protocol AttemptRepository { func record(_ attempt: Attempt) async throws; func progress(in: ClassID) -> [QuestionProgress]; func attempts(for: QuestionID) }
public protocol MessageRepository { func messages(for: ClassID, question: QuestionID?) ; func append(_:) ; func clear(for: ClassID, question: QuestionID?) }
public protocol SettingsRepository { func get<T: Codable>(_ key: SettingsKey, as: T.Type) async throws -> T?; func set<T: Codable>(_:_:) }
```
`Store` conforms to all of them. `QuestionFilter` = kinds, statuses, documentIds, search text. Progress rule (in
`ProgressRules`): correct on first try twice in a row ⇒ mastered; any correct ⇒ learning; wrong after mastered ⇒
needsReview.

## Theme (ThubanCore/Theme) — colors only from Atlas; UI is Thuban's own

```swift
public enum AppearanceMode: String, Codable, CaseIterable { case auto, light, dark }
public struct ColorScheme: Codable, Sendable { id, label, accent, signal, pos, neg, darkBg, darkPanel, lightBg, lightPanel }   // hex strings
public enum SchemePresets { public static let all: [ColorScheme] /* brass, cobalt, emerald, rose, violet, slate, ember, moss */; public static let defaultId = "brass" }
public struct ThemeSelection: Codable { var mode: AppearanceMode; var schemeId: String; var custom: ColorScheme? }   // schemeId == "custom" uses custom
public struct ResolvedTheme: Sendable {    // all hex strings, computed by ThemeResolver.resolve(selection, systemIsDark:)
  bg, panel, panel2, line, line2, ink, inkDim, inkFaint, accent, accentText, accentDeep, accentTint, onAccent,
  signal, signalText, pos, posText, neg, negText, posSoft, negSoft, warnSoft, signalSoft; isDark: Bool
  public var cssVariables: String   // ":root{--bg:#…;…}" for the web views
}
```
Ink ramps per mode: light ink #161a21 / #535a68 / #858c9b (rgb 22,26,33); dark #e9e7df / #9aa0ad / #5c616e
(rgb 202,214,242). `ColorMath` provides parseHex, toHex, shade(f), luminance, contrast, `legible(hex, on:bg, target:)`
(walk both directions ×1.12/×0.88 up to 24 steps, keep the better) and `onAccent` (pick #14100a vs #f7f5ef at ≥4.5:1).
panel2 = mix(panel, ink 6%); line = ink at 8% over bg; line2 at 15%; accentTint = accent at 14% over panel;
accentText = legible(accent, bg, 4.5); accentDeep = shade(accent, 0.72); *Text variants = legible(x, bg, 4.5);
*Soft = color at 18% over panel. Preset values: `docs/atlas-theme.md`.

## MathEngine (ThubanCore/MathEngine) — JavaScriptCore + Compute Engine

`public actor MathEngine` loads `compute-engine.umd.cjs` from `Bundle.module` into a `JSContext` once
(shim: `var module={exports:{}}; var exports=module.exports;` before evaluating; then `module.exports.ComputeEngine`).
Wrap every JS call with exception capture (`context.exceptionHandler`). Keep a single `ce` instance.

```swift
public struct Verdict: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable { case correct, incorrect, equivalentButConditionFailed, unparseable, needsTutor }
  public var outcome: Outcome; public var message: String      // student-facing, e.g. "Equivalent, but this part requires a rationalized denominator."
  public var canonicalStudent: String?; public var canonicalExpected: String?    // simplified latex for display/debug
  public var failedConditions: [String]                        // machine names: "rationalizedDenominator", "exactForm", …
}
public func grade(student latex: String, expected: AnswerSpec, conditions: AnswerConditions, kind: AnswerKind) async -> Verdict
public func instantiate(_ template: MathTemplate, seed: String?) async throws -> QuestionInstance   // deterministic for a seed
public func validate(_ template: MathTemplate) async -> [String]      // errors; used by the import pipeline (3 trial seeds)
public func evaluate(_ latex: String) async throws -> String           // for the fallback calculator: N() latex
public func simplify(_ latex: String) async throws -> String
```
Grading algorithm (`GradingRules`):
1. Parse both; unparseable ⇒ `.unparseable` with a gentle message.
2. Equations (`Equal` head): move everything to one side for each; two equations are equivalent if the difference
   expressions are equal up to a nonzero constant factor (test `isEqual` after dividing by leading coefficient, then a
   numeric fallback: sample 8 random points in [-3,3] for the free variables, ratios agree within 1e-9).
3. Expressions: `A.isEqual(B) == true` ⇒ equivalent; else `simplify(A − B)` is exactly 0 ⇒ equivalent; else numeric
   sampling at 12 random points (skip points where either side is non-finite) with relative tolerance 1e-9 ⇒
   equivalent (this is what makes (x+1)^2 ≡ x^2+2x+1 robust). Vectors/tuples/lists: componentwise. Sets of
   solutions (`x = 2, x = -2` or a comma list): order-insensitive multiset comparison.
4. Exactness: if `conditions.roundingDecimals == nil` and the student's expression contains a decimal literal that is
   not exactly equal to the expected value (e.g. 0.6247 vs 28/√2009) ⇒ `.equivalentButConditionFailed` with
   failedConditions ["exactForm"]. 0.5 for 1/2 passes because it is exactly equal. If rounding allowed, accept
   numeric agreement within 0.5·10^−decimals (or `tolerance`).
5. Conditions, checked only after equivalence succeeds: rationalizedDenominator (walk MathJSON: no `Sqrt`/`Root`/
   fractional `Power` inside any `Divide` denominator or negative exponents of radicals); simplified (student's
   `simplify()` latex equals the student's own canonical latex — i.e. simplifying changes nothing — plus no
   reducible numeric fractions); factored (head is `Multiply`/`Power` of sums, or expression equals its `factor()`
   form and not its `expand()` form when they differ); expanded (equals `expand()` form); explicit (equation with lone
   dependent variable on one side); units (trailing text matches).
6. Messages are friendly and specific; never reveal the expected answer in the message.

Template instantiation: seeded PRNG (SplitMix64 from the seed hex) for reproducibility; up to 200 draws to satisfy
constraints; substitute params into stem/prompts (`{a}` → number, negative numbers parenthesised when preceded by an
operator; a coefficient of 1 dropped when the template marks `{a}x` — implement simple `coefficient` formatting);
evaluate each `answerExpr` with `ce.parse(expr).subs(params).evaluate()` and keep `.latex`; return the instance.

## Documents (ThubanCore/Documents)

```swift
public struct DocumentContent: Sendable { public var blocks: [ContentBlock]; public var figures: [ExtractedFigure]; public var pageCount: Int?; public var warnings: [String] }
public enum ContentBlock: Sendable { case heading(String, level: Int), paragraph(String), list([String]), table([[String]]), code(String), pageBreak(Int), image(index: Int) }
public struct ExtractedFigure: Sendable { public var index: Int; public var page: Int?; public var pngData: Data; public var nearbyText: String }
public protocol DocumentParser: Sendable { static var kinds: [DocumentKind] { get }; func parse(url: URL) async throws -> DocumentContent }
public enum DocumentParserRegistry { public static func parser(for url: URL) -> DocumentParser?; public static func kind(for url: URL) -> DocumentKind }
```
Parsers: `PDFParser` (PDFKit text per page; images: render each page to CGImage and detect embedded image
XObjects via `PDFPage` annotations/`CGPDFScanner` — acceptable simplification: extract `PDFPage` image bounds by
scanning the content stream with CGPDFScanner for `Do` operators, and for scanned pages run Vision
`VNRecognizeTextRequest` OCR when a page has < 20 chars of text), `DocxParser` (ZIPFoundation → word/document.xml
via SwiftSoup xml parser; paragraphs, headings by style, tables, `word/media/*` images with their order),
`PptxParser` (slides text + media), `XlsxParser` (CoreXLSX rows → tables per sheet), `CsvParser`,
`HtmlParser` (SwiftSoup: headings, paragraphs, lists, tables, <img> with data: or local src), `MhtmlParser` (MIME
multipart → the text/html part + image parts by Content-Location/CID → HtmlParser), `MarkdownParser`,
`TextParser`, `ImageParser` (Vision OCR text + the image itself as a figure).
`Chunker.chunks(_ content: DocumentContent, maxTokens: 12_000)` returns `[DocumentChunk]` (text, page range, figure
indices) sized for the import agent.

## AI (ThubanCore/AI)

```swift
public enum ClaudeModel: String, Codable, CaseIterable, Sendable { case sonnet = "claude-sonnet-5", opus = "claude-opus-5", haiku = "claude-haiku-4-5-20251001" }
public enum ClaudeAuth: Sendable { case oauth(accessToken: String), apiKey(String) }

public struct ChatMessage: Codable, Sendable { public var role: String /* user|assistant */; public var content: [ContentPart] }
public enum ContentPart: Codable, Sendable { case text(String), image(mediaType: String, base64: String), toolUse(id: String, name: String, input: JSONValue), toolResult(toolUseId: String, content: String, isError: Bool) }
public struct ToolSpec: Codable, Sendable { public var name: String; public var description: String; public var inputSchema: JSONValue }
public enum StreamEvent: Sendable { case textDelta(String), toolUseStart(id: String, name: String), toolInputDelta(String), toolUseEnd(id: String, name: String, input: JSONValue), messageEnd(stopReason: String, usage: Usage), error(Error) }

public actor ClaudeClient {
  public init(authProvider: @Sendable () async throws -> ClaudeAuth)
  public func stream(model: ClaudeModel, system: String, messages: [ChatMessage], tools: [ToolSpec], maxTokens: Int, thinking: Bool) -> AsyncThrowingStream<StreamEvent, Error>
  public func complete(...) async throws -> (parts: [ContentPart], stopReason: String, usage: Usage)   // non-streaming convenience
}
```
HTTP: `POST https://api.anthropic.com/v1/messages`, headers `anthropic-version: 2023-06-01`, `content-type: application/json`,
`accept: text/event-stream` when streaming; auth: apiKey ⇒ `x-api-key`, oauth ⇒ `Authorization: Bearer <token>` plus
`anthropic-beta: oauth-2025-04-20`. SSE parsing handles `message_start`, `content_block_start/delta/stop`,
`message_delta`, `message_stop`, `error`, `ping`. Retries: 429/529/5xx with exponential backoff (3 tries).

OAuth (personal-use flow, mirrors the Claude Code CLI):
```swift
public struct OAuthConfig { clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"; authorizeURL = "https://claude.ai/oauth/authorize";
  tokenURL = "https://console.anthropic.com/v1/oauth/token"; redirectURI = "https://console.anthropic.com/oauth/code/callback";
  scopes = "org:create_api_key user:profile user:inference" }
public actor OAuthFlow { public func begin() -> (url: URL, state: String)  // PKCE S256: verifier 32 random bytes base64url, challenge = base64url(sha256(verifier)); query: code=true, client_id, response_type=code, redirect_uri, scope, code_challenge, code_challenge_method=S256, state
  public func exchange(pastedCode: String) async throws -> OAuthTokens   // pasted value may be "code#state"; POST JSON {grant_type:"authorization_code", code, state, client_id, redirect_uri, code_verifier}
  public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens // {grant_type:"refresh_token", refresh_token, client_id}
}
public struct OAuthTokens: Codable, Sendable { accessToken, refreshToken, expiresAt: Date, scopes: [String], accountEmail: String? }
public enum Keychain { static func save(_ data: Data, account: String) throws; static func load(account:) throws -> Data?; static func delete(account:) }   // service "com.thuban.study"
public actor CredentialStore { public func currentAuth() async throws -> ClaudeAuth   // oauth (auto-refresh 5 min before expiry) else api key else throws NotConnected
  public func setAPIKey(_:) ; public func setOAuth(_:) ; public func disconnect() ; public var status: ConnectionStatus }
```

Agents (`ThubanCore/AI/Agents`):
- `TutorAgent` — `func respond(context: TutorContext, transcript: [TutorMessage], student: String, solutionRequested: Bool, tools: TutorToolHandler) -> AsyncThrowingStream<TutorEvent, Error>`.
  System prompt (in `Prompts.tutorSystem(style:)`): you are the Thuban tutor for <class>; the student is working on
  <question instance with their current inputs and verdicts>; you GUIDE: ask one question at a time, point at the
  relevant idea, check the student's reasoning, suggest the next small step; NEVER give the final answer, the full
  solution, or the algebra that completes a part unless `solutionRequested` is true for the current message (then
  give a complete worked solution and say so). Use $…$ for math. You may use graph tools to illustrate; when you add
  something to the graph, say what you added. Tools (`TutorTools.specs`):
  `show_graph {mode: "2d"|"3d"}`, `hide_graph {}`, `graph_add_expression {id, latex, color?, dashed?: bool, label?, hidden?}`,
  `graph_remove_expression {id}`, `graph_clear {}`, `graph_set_viewport {xmin,xmax,ymin,ymax}`, `show_calculator {}`,
  `get_student_work {}` (returns current inputs/verdicts). `TutorToolHandler` is a protocol the app implements.
- `ImportAgent` — `func run(document: ImportedDocument, content: DocumentContent, classContext: String, policy: ModelPolicy, progress: @Sendable (ImportProgress) -> Void) async throws -> ImportResult` (questions, figures needing analysis, modelUsed).
  Per chunk: tool `classify_document {classification, reasoning}` first (once), then `emit_questions {questions: [QuestionDraft]}`
  where a QuestionDraft mirrors `Question` + optional `template` (the agent writes MathTemplate JSON for math
  questions: params, constraints, stem with placeholders, parts with answerExpr in LaTeX). Tool
  `escalate_model {reason}` — when called with Sonnet, the agent stops, the pipeline reruns the chunk with Opus and
  records `escalated`. Existing-questions documents: extract the questions faithfully (keep numbering in sourceRef,
  keep given answers if present as `answer.latex`); readings: generate 6–12 questions per chunk mixing kinds; every
  math question with numbers becomes a template. Templates are validated with `MathEngine.validate`; on failure the
  agent gets one repair turn with the errors; if still failing, the question is stored as static (`kind` downgraded).
- `FigureAgent` — `func analyze(png: Data, nearbyText: String) async throws -> FigureAnalysis` (kind; if chart: StandardChart via
  tool `describe_chart`). Uses Sonnet with an image content part.
- `ModelPolicy { defaultModel: .sonnet, allowEscalation: Bool = true, pinned: ClaudeModel? }`.

## Web bridge protocols (Swift ⇄ JS)

All pages include `web/shared/bridge.js` which defines `window.thuban.send(type, payload)` →
`webkit.messageHandlers.thuban.postMessage({type, payload})` and `window.thuban.receive = (type, payload) => …`
dispatch table; Swift calls `window.thuban.receive(type, payloadJSON)` via `evaluateJavaScript`. Every page posts
`{type:"ready"}` when loaded. Theme: Swift sends `{type:"theme", payload:{css: "<:root{…}>", isDark}}`; pages apply it
to a `<style id="theme">` element and set `data-theme` on `<html>`.

Sends are queued in `WebBridge` until the page posts `ready`; a page reload drops that queue (every controller
rebuilds its full state in its `ready` handler) and replays only the theme and the page's *sticky* messages (one per
type — `config` below).

question.html (`QuestionFormWebView`):
- Swift → JS: `load {instance: QuestionInstanceView}` where the view is `{questionId, seed, stem, parts:[{id, prompt,
  answerKind, choices?, conditionsText, value?, verdict?}]}` — never the answers; a `verdict` is the page projection
  `{outcome, message, failedConditions}` (no `canonicalStudent` / `canonicalExpected`);
  `setVerdicts {verdicts: {partId: verdict}}` (same projection); `setKeyboardVisible {visible}`; `focusPart {partId}`;
  `insert {latex}` (from the calculator "copy to answer").
- JS → Swift: `ready`; `input {partId, latex, ascii}` (debounced 150 ms); `submit {}` (Enter on the last field or Cmd+Enter);
  `keyboardVisible {visible}`; `height {px}`.
- MathLive setup: `MathfieldElement.fontsDirectory = "thuban://bundle/vendor/mathlive/fonts"`, `soundsDirectory = null`,
  `mathVirtualKeyboardPolicy = "manual"`; inline shortcuts extend the defaults (theta/Theta/pi/…, `sqrt`→`\sqrt`,
  `int`→`\int`, `sum`, `lim`, `dx`/`dy`/`dt` → `\mathrm{d}x`, `d/dx`); `smartFence`, `smartSuperscript`; `/` makes a
  fraction (default). Custom virtual keyboard layouts — NO letters, NO digits: "Operators", "Structure",
  "Calculus", "Functions", "Greek" (lower/upper toggle), "Sets & vectors" (see design board Math-Keyboard).
  Function names render upright automatically (\sin etc.); ensure `d` in derivatives uses `\mathrm{d}`.
- Static math in stems/prompts: `renderMathInElement` from MathLive, Markdown via marked + DOMPurify.

graph.html (`GraphWebView`) — Desmos:
- loads `https://www.desmos.com/api/v1.11/calculator.js?apiKey=<key>` (key injected by Swift via the sticky
  `config {desmosKey, mode?: "2d"|"3d"}` before init; page shows an inline notice if the script fails).
- Swift → JS: `setMode {mode:"2d"|"3d"}` (creates `Desmos.GraphingCalculator` or `Desmos.Calculator3D` in the container;
  keeps expression lists per mode — Swift follows every `setMode` with `setExpressions` for that mode, because the
  session's per-mode rows are the source of truth), `setExpressions {expressions:[{id, latex, color?, lineStyle?:"SOLID"|"DASHED"|"DOTTED", label?, showLabel?, hidden?, sliderBounds?}]}`
  (replaces the rows of the mode on screen, viewport kept), `addExpression {…}`, `removeExpression {id}`, `clear {}`,
  `setViewport {xmin,xmax,ymin,ymax}`, `getState {}`, `setState {state}`, `resetView {}`.
- JS → Swift: `ready`, `expressionsChanged {expressions:[{id, latex}], mode}` (observer on the calculator; debounced;
  only the calculator on screen), `state {state, mode}` (reply to `getState`), `error {message}`.
- Options: `{expressions: true, keypad: false, settingsMenu: true, zoomButtons: true, border: false, lockViewport: false}`;
  colors default to the theme accent for user rows; tutor-added rows use `signal` (solid) or `accentDeep` dashed.
  Theming: 2D (and the scientific calculator) pass Desmos' own `backgroundColor`/`textColor`/`accentColor` settings
  from `--panel`/`--ink`/`--accent` (never together with `invertedColors`, which is a CSS invert filter over the
  whole calculator); 3D uses `invertedColors: isDark` because its plane material keys off it.

calc.html (`CalculatorWebView`): Swift → JS: sticky `config {desmosKey, forceFallback?}` (an empty key or
`forceFallback` shows the fallback right away), `result {id, latex}` | `result {id, error}`. `Desmos.ScientificCalculator(elt, {})`
when the key allows it; if `Desmos.ScientificCalculator` is undefined or errors, a fallback: a MathLive field evaluated
by Swift (`evaluate {latex, id}` → `result` via `MathEngine.evaluate`). JS → Swift: `ready`, `evaluate {latex, id}`,
`copyToAnswer {latex}`, `error {message}`.

chat.html (`ChatWebView`): Swift → JS: `setTranscript {messages:[{id, role, html?, markdown, toolEvents, streaming}]}`,
`appendMessage {message}` (adds or replaces by id), `appendDelta {id, text, role?}`, `finish {id, markdown?}`, `clear {}`;
JS renders markdown (marked + DOMPurify) then `renderMathInElement`. Auto-scrolls when at bottom.
JS → Swift: `ready`, `linkClicked {href, url}` (`href` as written, `url` resolved).

## App target

- `AppModel` (@MainActor @Observable): store, engine, credentials, theme selection + resolved theme, classes,
  selected class, per-class `ClassSession` (section, current question instance, inputs, verdicts, graph state,
  toggles, tutor transcript, import queue). Persists UI state in Settings (`SettingsKey.lastClass`, `.theme`, `.modelPolicy`, `.desmosKey`).
- Shell: `ShellView` (title bar with app mark + name, class tabs (drag to reorder optional), + button, connection chip,
  Settings), `SectionBar` (Study | Question Bank | Import; Study toggles Graph / Calculator / Keyboard; "Question n of N").
- Study: `StudyView` = HStack: `QuestionPane` (QuestionFormWebView + action bar: Check answers, Regenerate numbers
  (templates only), Show a hint (asks tutor for a hint), Source link, bank progress bar) | optional `GraphPane`
  (GraphWebView + header with 2D/3D segmented, reset, "Tutor is editing" chip when the tutor changed it in the last
  5 s, close) | `TutorPane` (header with "Guides, never solves" chip, model chip, clear; ChatWebView; composer =
  native TextEditor + Send + "Ask for the solution" (sets solutionRequested on that message, shows a confirm popover
  "The tutor will give the complete solution for this question. Continue?")). Calculator: floating `CalculatorPanel`
  (an NSPanel-style utility window or overlay, 360×420, draggable). Keyboard: sends setKeyboardVisible to the form.
  Check answers → `MathEngine.grade` per part → verdict badges in the form + `AnswerResultsSheet` (design board
  Modal-Answer-Result) → `Attempt` recorded, progress updated, then "Next question".
  Question order in Study: needsReview first, then new, then learning, mastered last; "Next" advances.
- QuestionBank: `QuestionBankView` (filters, table, source rail with Figures entry, row → study it; edit question sheet
  minimal: stem/parts text; delete).
- Import: `ImportView` (drop zone via `.dropDestination(for: URL.self)` + NSOpenPanel; file rows with statuses and
  progress; right rail cards; `ImportProgressSheet` (escalation notice with Keep Opus / Use Sonnet anyway = sets
  policy.pinned for this run); `FigureReviewView` (original vs standardized via a small GraphWebView rendering the
  StandardChart; accept / keep original / skip; prev/next).
- Settings: `SettingsView` window (Appearance: mode segmented, 9 scheme cards, preview, Custom… → `CustomSchemeSheet`
  (design board Modal-Custom-Scheme: two live previews, 8 slot rows with hex fields, hue/lightness/saturation for the
  selected slot, suggestions, Derive from accent, Reset, Start from); Claude account: status card, Connect (→
  `ConnectClaudeSheet` 3-step stepper: open browser, paste code, connected) / API key field / Disconnect; Agents:
  tutor model picker, "may escalate to Opus" toggle, "tutor may edit the graph" toggle; Grapher: Desmos key field
  (seeded from Secrets.plist); Data & storage: path, size, Export (zip of DB + files), Reveal in Finder; About).
- Modals: `DeleteClassAlert` (confirmation with checkbox "Also delete imported files"), `NewClassSheet`.
- App mark: `ThubanMark` SwiftUI `Shape`/`Path` from the icon set; `AppIconRenderer` draws the squircle plate (bg) +
  mark (accent) and sets `NSApp.applicationIconImage` whenever the theme changes.
- Menu commands: New Class ⌘N, Import ⌘I, Toggle Graph ⌘G, Toggle Calculator ⌘K, Toggle Keyboard ⌘⇧K, Check Answers ⌘⏎, Next Question ⌘→.

## Conventions

- Swift 5 language mode, `-strict-concurrency=minimal`. `@MainActor` on all view models. No force unwraps outside
  tests. Errors are typed `ThubanError` (enum with `LocalizedError`).
- Logging via `os.Logger(subsystem: "com.thuban.study", category:)`.
- Tests in `Packages/ThubanCore/Tests`: MathEngine grading matrix (≥40 cases incl. every condition), template
  instantiation determinism, theme resolver contrast (every preset, both modes: ink ≥ 7:1, accentText ≥ 4.5:1),
  SSE parser, OAuth PKCE + code parsing, document parsers on tiny fixtures (generated in-test), Store CRUD + migrations.
- Build: `scripts/build.sh` = `xcodebuild -project ThubanStudy.xcodeproj -scheme ThubanStudy -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build`.
