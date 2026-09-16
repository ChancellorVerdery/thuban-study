import SwiftUI
import ThubanCore

/// PLACEHOLDER — the screens phase replaces this file wholesale.
/// Question form | optional graph | tutor transcript, wired to the session's state.
struct StudyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    @State private var form = QuestionFormWebView.Controller()
    @State private var chat = ChatWebView.Controller()
    @State private var graph: GraphWebView.Controller?

    var body: some View {
        HStack(spacing: 0) {
            questionPane
                .frame(minWidth: 420)
                .frame(maxWidth: session.showGraph ? 520 : .infinity)
            if session.showGraph {
                graphPane
                    .frame(minWidth: 360, maxWidth: .infinity)
                    .thubanHairline(.leading, color: theme.lineColor)
            }
            tutorPane
                .frame(width: 400)
                .thubanHairline(.leading, color: theme.lineColor)
        }
        .task(id: session.classId) {
            if session.questions.isEmpty { await session.loadQuestions() }
        }
        .onAppear { wire() }
        .onChange(of: session.currentInstance) { _, instance in
            guard let instance else { return }
            form.load(instance: instance, inputs: session.inputs, verdicts: session.verdicts)
        }
        .onChange(of: session.verdicts) { _, verdicts in form.setVerdicts(verdicts) }
        .onChange(of: session.showKeyboard) { _, visible in form.setKeyboardVisible(visible) }
        .onChange(of: session.transcript) { _, transcript in chat.setTranscript(transcript) }
        .onChange(of: session.showGraph, initial: true) { _, shown in
            if shown, graph == nil { graph = GraphWebView.Controller(desmosKey: app.desmosKey, mode: session.graphMode) }
        }
        .onChange(of: session.graphMode) { _, mode in graph?.setMode(mode) }
        .onChange(of: session.graphExpressions) { _, expressions in graph?.setExpressions(expressions) }
    }

    private func wire() {
        form.onInput = { partId, latex, _ in session.inputs[partId] = latex }
        form.onSubmit = { app.perform(.checkAnswers) }
        form.onKeyboardVisible = { visible in if session.showKeyboard != visible { session.showKeyboard = visible } }
        form.onReady = {
            if let instance = session.currentInstance {
                form.load(instance: instance, inputs: session.inputs, verdicts: session.verdicts)
            }
            form.setKeyboardVisible(session.showKeyboard)
        }
        chat.onReady = { chat.setTranscript(session.transcript) }
    }

    // MARK: Panes

    private var questionPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(session.questionCount == 0 ? "No questions yet" : "Question \(session.questionNumber) of \(session.questionCount)")
                    .font(ThubanFont.display(18))
                    .foregroundStyle(theme.inkColor)
                if let question = session.currentQuestion {
                    Chip.status(session.status(of: question))
                    if question.kind == .mathTemplate, let instance = session.currentInstance {
                        Chip("Regenerated · seed \(instance.seed.prefix(4))", kind: .accent, icon: .mathEngine)
                    }
                }
                Spacer()
            }
            if session.currentQuestion == nil {
                EmptyState(icon: .questionBank, title: "Nothing to study yet",
                           message: "Import documents to build this class's question bank.") {
                    Button("Import documents") { session.section = .importDocs }
                        .buttonStyle(.thubanPrimary)
                }
                .thubanPanel(padding: 0)
            } else {
                QuestionFormWebView(controller: form)
                    .thubanPanel(padding: 0)
                    .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
            }
            HStack(spacing: 10) {
                Button("Check answers") { app.perform(.checkAnswers) }
                    .buttonStyle(.thubanPrimary)
                    .disabled(session.currentInstance == nil)
                if session.currentQuestion?.kind == .mathTemplate {
                    Button {
                        Task { await session.regenerate() }
                    } label: {
                        HStack(spacing: 6) { Icon(.mathEngine, size: 16); Text("Regenerate numbers") }
                    }
                    .buttonStyle(.thubanSecondary)
                }
                Button("Next question") { session.next() }
                    .buttonStyle(.thubanGhost)
                    .disabled(session.questionCount < 2)
                Spacer()
                if let source = session.currentQuestion?.sourceRef {
                    Text("Source: \(source)")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.brassInkColor)
                }
            }
            ProgressBar(value: session.masteredFraction)
        }
        .padding(16)
    }

    private var graphPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SegmentedPicker(selection: $session.graphMode, options: [
                    SegmentOption(.twoD, "2D", icon: .graph2D),
                    SegmentOption(.threeD, "3D", icon: .graph3D),
                ], segmentHeight: 26)
                if session.tutorEditedRecently { Chip("Tutor is editing", kind: .accent) }
                Spacer()
                Button("Reset view") { graph?.resetView() }
                    .buttonStyle(GhostButtonStyle(height: 28))
                IconButton(glyph: .close, label: "Close graph", size: 28, iconSize: 14) { session.showGraph = false }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .thubanHairline(.bottom, color: theme.lineColor)
            if let graph {
                GraphWebView(controller: graph)
            } else {
                Color.clear
            }
        }
        .background(theme.panelColor)
    }

    private var tutorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Icon(.tutor, size: 18).foregroundStyle(theme.brassInkColor)
                Text("Tutor")
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
                Chip("Guides, never solves", kind: .accent)
                Spacer()
                Chip(app.modelPolicy.effectiveModel.shortName, kind: .neutral)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .thubanHairline(.bottom, color: theme.lineColor)
            ChatWebView(controller: chat)
            HStack(spacing: 8) {
                Text(app.isConnected ? "The tutor composer arrives with the Study screen." : "Connect your Claude account in Settings to talk to the tutor.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                Spacer()
            }
            .padding(12)
            .thubanHairline(.top, color: theme.lineColor)
        }
        .background(theme.panelColor)
    }
}
