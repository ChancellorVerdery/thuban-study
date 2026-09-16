import SwiftUI
import ThubanCore

/// Left pane: eyebrow + chips, attached figures, the MathLive answer form, the action bar and the bank progress row.
struct QuestionPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    private var state: StudyState { session.studyState }
    private var form: QuestionFormWebView.Controller { state.form }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if session.isLoadingQuestions && session.questions.isEmpty {
                loading("Loading the question bank…")
            } else if session.currentQuestion == nil {
                EmptyState(icon: .questionBank, title: "Nothing to study yet",
                           message: "Import documents to build this class's question bank; the agent turns readings and homework into questions.") {
                    Button("Import documents") { app.perform(.importDocuments) }
                        .buttonStyle(.thubanPrimary)
                }
                .thubanPanel(padding: 0)
            } else {
                formCard
                actionBar
            }
            progressRow
        }
        .padding(16)
        .background(theme.bgColor)
        .onAppear { wireForm() }
        .onChange(of: session.currentInstance) { _, instance in
            guard let instance else { return }
            form.load(instance: instance, inputs: session.inputs, verdicts: session.verdicts)
        }
        .onChange(of: session.verdicts) { _, verdicts in
            form.setVerdicts(verdicts)
        }
        .onChange(of: session.showKeyboard) { _, visible in
            if form.isKeyboardVisible != visible { form.setKeyboardVisible(visible) }
        }
    }

    // MARK: Wiring

    private func wireForm() {
        let session = session
        let form = form
        let state = state
        form.onInput = { partId, latex, _ in
            session.inputs[partId] = latex
        }
        form.onSubmit = {
            guard !state.isGrading else { return }
            Task { await session.checkAnswers() }
        }
        form.onHeight = { height in
            state.formHeight = height
        }
        form.onKeyboardVisible = { visible in
            if session.showKeyboard != visible { session.showKeyboard = visible }
        }
        form.onReady = {
            // Pages start blank on (re)load.
            if let instance = session.currentInstance {
                form.load(instance: instance, inputs: session.inputs, verdicts: session.verdicts)
            }
            form.setKeyboardVisible(session.showKeyboard)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.questionEyebrow.isEmpty ? "Study" : session.questionEyebrow)
                    .font(ThubanFont.micro)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(theme.inkDimColor)
                    .lineLimit(1)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            if let question = session.currentQuestion {
                HStack(spacing: 6) {
                    Chip.kind(question.kind)
                    if question.kind == .mathTemplate, let instance = session.currentInstance {
                        Chip("Regenerated · seed \(instance.seed.prefix(4))", kind: .neutral)
                            .monospacedDigit()
                    }
                    Chip.status(session.status(of: question))
                    if question.difficulty > 0 {
                        Text(String(repeating: "●", count: min(5, max(1, question.difficulty))))
                            .font(.system(size: 7))
                            .foregroundStyle(theme.inkFaintColor)
                            .accessibilityLabel("Difficulty \(question.difficulty) of 5")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Form

    private var formCard: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if !state.figures.isEmpty {
                    FigureStrip(figures: state.figures)
                }
                ZStack(alignment: .top) {
                    QuestionFormWebView(controller: form)
                        .frame(height: max(state.formHeight, 240))
                        .opacity(session.isInstantiating && session.currentInstance == nil ? 0 : 1)
                    if session.isInstantiating && session.currentInstance == nil {
                        loading("Preparing fresh numbers…")
                            .frame(height: 240)
                    }
                }
                .thubanPanel(padding: 0)
                .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if session.isInstantiating && session.currentInstance != nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .accessibilityLabel("Preparing fresh numbers")
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loading(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(text)
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await session.checkAnswers() }
            } label: {
                HStack(spacing: 6) {
                    if state.isGrading {
                        ProgressView().controlSize(.small)
                    }
                    Text(state.isGrading ? "Checking…" : "Check answers")
                }
            }
            .buttonStyle(.thubanPrimary)
            .disabled(session.currentInstance == nil || state.isGrading)
            .help("Check answers (⌘⏎)")

            if session.currentQuestion?.kind == .mathTemplate {
                Button {
                    Task { await session.regenerate() }
                } label: {
                    HStack(spacing: 6) {
                        Icon(.mathEngine, size: 16)
                        Text("Regenerate numbers")
                    }
                }
                .buttonStyle(.thubanSecondary)
                .disabled(session.isInstantiating)
                .help("Fresh numbers for this question (⌘⇧R)")
            }

            Button("Show a hint") { session.askForHint() }
                .buttonStyle(.thubanGhost)
                .disabled(session.isTutorStreaming || session.currentInstance == nil)
                .help("Ask the tutor for a small hint")

            Spacer(minLength: 8)

            if let source = session.currentQuestion?.sourceRef, !source.isEmpty {
                Text("Source: \(source)")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.brassInkColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: Progress row

    private var progressRow: some View {
        let counts = session.progressCounts
        return VStack(alignment: .leading, spacing: 6) {
            ProgressBar(value: session.masteredFraction)
            HStack(spacing: 8) {
                Text(progressCaption(counts))
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
                Spacer()
                if session.questionCount > 1 {
                    Button {
                        session.previous()
                    } label: {
                        HStack(spacing: 4) { Glyph(.chevronLeft, size: 14); Text("Previous") }
                    }
                    .buttonStyle(GhostButtonStyle(height: 26, horizontalPadding: 8))
                    Button {
                        session.next()
                    } label: {
                        HStack(spacing: 4) { Text("Next question"); Glyph(.chevronRight, size: 14) }
                    }
                    .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 8))
                    .help("Next question (⌘→)")
                }
            }
        }
    }

    private func progressCaption(_ counts: (mastered: Int, learning: Int, new: Int, needsReview: Int)) -> String {
        guard session.questionCount > 0 else { return "No questions in the bank yet" }
        var pieces = ["\(counts.mastered) mastered", "\(counts.learning) learning", "\(counts.new) new"]
        if counts.needsReview > 0 { pieces.append("\(counts.needsReview) to review") }
        return pieces.joined(separator: " · ")
    }
}

// MARK: - Figures

/// Figures attached to the question: accepted charts redraw in the app's graph style, everything else shows the
/// original clipping.
struct FigureStrip: View {
    var figures: [Figure]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(figures) { figure in
                FigureCard(figure: figure)
            }
        }
    }
}

struct FigureCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var figure: Figure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Icon(.figureClip, size: 14)
                    .foregroundStyle(theme.brassInkColor)
                Text(figure.caption?.nilIfEmpty ?? "Figure")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .lineLimit(2)
                Spacer()
                if isStandardized {
                    Chip("Standardized", kind: .signal)
                }
            }
            if isStandardized, let chart = figure.chart {
                StandardChartView(chart: chart)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
            } else if let image = NSImage(contentsOf: AppPaths.figureURL(figure.originalPath)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                    .accessibilityLabel(figure.caption ?? "Figure")
            } else {
                Text("The figure file is missing.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkFaintColor)
            }
        }
        .thubanPanel(padding: 12)
    }

    private var isStandardized: Bool {
        figure.chart != nil && figure.status == .accepted && app.hasDesmosKey
    }
}

/// A `StandardChart` drawn by a small Desmos grapher: point series as point lists, LaTeX series as functions.
struct StandardChartView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var chart: StandardChart
    @State private var controller: GraphWebView.Controller?

    var body: some View {
        Group {
            if let controller {
                GraphWebView(controller: controller)
            } else {
                theme.panel2Color
            }
        }
        .onAppear {
            guard controller == nil else { return }
            let controller = GraphWebView.Controller(desmosKey: app.desmosKey, mode: .twoD)
            controller.onReady = { [weak controller] in
                guard let controller else { return }
                controller.setExpressions(Self.expressions(for: chart))
                if let viewport = Self.viewport(for: chart) { controller.setViewport(viewport) }
            }
            self.controller = controller
        }
    }

    static func expressions(for chart: StandardChart) -> [GraphExpression] {
        chart.series.enumerated().compactMap { index, series in
            let id = "series\(index)"
            if let latex = series.latex?.trimmingCharacters(in: .whitespaces), !latex.isEmpty {
                let expression = latex.contains("=") ? latex : "y=\(latex)"
                return GraphExpression(id: id, latex: expression, color: series.color, label: series.name.nilIfEmpty)
            }
            if let points = series.points, !points.isEmpty {
                let list = points.compactMap { point -> String? in
                    guard point.count >= 2 else { return nil }
                    return "(\(Self.number(point[0])),\(Self.number(point[1])))"
                }
                guard !list.isEmpty else { return nil }
                return GraphExpression(id: id, latex: "[" + list.joined(separator: ",") + "]", color: series.color, label: series.name.nilIfEmpty)
            }
            return nil
        }
    }

    static func viewport(for chart: StandardChart) -> GraphViewport? {
        guard let x = chart.xRange, x.count == 2, let y = chart.yRange, y.count == 2, x[0] < x[1], y[0] < y[1] else { return nil }
        return GraphViewport(xmin: x[0], xmax: x[1], ymin: y[0], ymax: y[1])
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(format: "%.6g", value)
    }
}
