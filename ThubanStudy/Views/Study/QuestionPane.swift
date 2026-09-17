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
                    Chip.type(question)
                    if question.kind == .mathTemplate, let instance = session.currentInstance {
                        Chip("Regenerated · seed \(instance.seed.prefix(4))", kind: .neutral)
                            .monospacedDigit()
                    }
                    Chip.status(session.status(of: question))
                    if session.isStudyingSelection {
                        Button {
                            Task { await session.clearStudySelection() }
                        } label: {
                            Chip("\(session.questionCount) selected · Study all", kind: .signal)
                        }
                        .buttonStyle(.plain)
                        .help("Return to the whole question bank")
                    }
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
        GeometryReader { geometry in
            formScroll(availableHeight: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The page reports its own height and the form hugs it. While the virtual keyboard is showing (it is fixed to
    /// the bottom of the page's viewport) the web view is capped to the visible height instead, so the keyboard
    /// docks at the bottom of the pane and the page scrolls internally above it.
    private func formHeight(availableHeight: CGFloat) -> CGFloat {
        let natural = max(state.formHeight, 240)
        guard session.showKeyboard, availableHeight > 240 else { return natural }
        return min(natural, availableHeight - 6)
    }

    private func formScroll(availableHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if !state.figures.isEmpty {
                    FigureStrip(figures: state.figures)
                }
                ZStack(alignment: .top) {
                    QuestionFormWebView(controller: form)
                        .frame(height: formHeight(availableHeight: availableHeight))
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
        // The single row is preferred; when the pane is narrow (graph open at the minimum window width) the
        // regenerate label shortens and the source caption drops to its own line instead of wrapping the buttons.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons(compact: false)
                Spacer(minLength: 8)
                sourceCaption
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    actionButtons(compact: true)
                    Spacer(minLength: 0)
                }
                sourceCaption
            }
        }
    }

    @ViewBuilder
    private func actionButtons(compact: Bool) -> some View {
        Button {
            Task { await session.checkAnswers() }
        } label: {
            HStack(spacing: 6) {
                if state.isGrading {
                    ProgressView().controlSize(.small)
                }
                Text(state.isGrading ? "Checking…" : "Check answers")
                    .lineLimit(1)
            }
        }
        .buttonStyle(.thubanPrimary)
        .fixedSize()
        .disabled(session.currentInstance == nil || state.isGrading)
        .help("Check answers (⌘⏎)")

        if session.currentQuestion?.kind == .mathTemplate {
            Button {
                Task { await session.regenerate() }
            } label: {
                HStack(spacing: 6) {
                    Icon(.mathEngine, size: 16)
                    Text(compact ? "Regenerate" : "Regenerate numbers")
                        .lineLimit(1)
                }
            }
            .buttonStyle(.thubanSecondary)
            .fixedSize()
            .disabled(session.isInstantiating)
            .help("Fresh numbers for this question (⌘⇧R)")
        }

        Button("Show a hint") { session.askForHint() }
            .buttonStyle(.thubanGhost)
            .fixedSize()
            .disabled(session.isTutorStreaming || session.currentInstance == nil)
            .help("Ask the tutor for a small hint")
    }

    @ViewBuilder
    private var sourceCaption: some View {
        if let source = session.currentQuestion?.sourceRef, !source.isEmpty {
            Text("Source: \(source)")
                .font(ThubanFont.small)
                .foregroundStyle(theme.brassInkColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Progress

    private var progressRow: some View {
        let counts = session.progressCounts
        return VStack(alignment: .leading, spacing: 6) {
            ProgressBar(value: session.masteredFraction)
            HStack(spacing: 8) {
                Text(progressCaption(counts))
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if session.questionCount > 1 {
                    Button {
                        session.previous()
                    } label: {
                        HStack(spacing: 4) { Glyph(.chevronLeft, size: 14); Text("Previous") }
                    }
                    .buttonStyle(GhostButtonStyle(height: 26, horizontalPadding: 8))
                    .fixedSize()
                    Button {
                        session.next()
                    } label: {
                        HStack(spacing: 4) { Text("Next question"); Glyph(.chevronRight, size: 14) }
                    }
                    .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 8))
                    .fixedSize()
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

/// A `StandardChart` drawn by a small Desmos grapher through `ChartRenderer` (curves, bars, slope fields).
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
            let controller = GraphWebView.Controller(desmosKey: app.desmosKey, mode: .twoD, showsExpressions: false)
            controller.onReady = { [weak controller] in
                guard let controller else { return }
                Task { @MainActor in
                    controller.setExpressions(await ChartRenderer.expressions(for: chart, theme: theme, engine: app.engine))
                    if let viewport = ChartRenderer.viewport(for: chart) { controller.setViewport(viewport) }
                }
            }
            self.controller = controller
        }
    }

}
