import SwiftUI
import ThubanCore

/// The Study screen: question form | optional resizable graph | tutor, with the floating calculator overlay,
/// the answer-check sheet, and the ⌘⏎ / hint command handlers.
struct StudyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    @State private var commandTokens: [UUID] = []

    private var state: StudyState { session.studyState }

    var body: some View {
        @Bindable var state = state
        GeometryReader { geometry in
            HStack(spacing: 0) {
                QuestionPane(session: session)
                    .frame(minWidth: StudyLayout.questionMinWidth, maxWidth: .infinity)

                if session.showGraph {
                    PaneDivider(width: $state.graphWidth, range: graphWidthRange(total: geometry.size.width))
                    GraphPane(session: session)
                        .frame(width: clampedGraphWidth(total: geometry.size.width))
                        .thubanHairline(.leading, color: theme.lineColor)
                }

                TutorPane(session: session)
                    .frame(width: StudyLayout.tutorWidth)
                    .thubanHairline(.leading, color: theme.lineColor)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .bottomTrailing) {
            if session.showCalculator {
                CalculatorPanel(session: session)
                    .padding(.trailing, StudyLayout.tutorWidth + 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .sheet(item: $state.results) { results in
            AnswerResultsSheet(session: session, results: results)
                .environment(\.thubanTheme, theme)
        }
        .task(id: session.classId) {
            if session.questions.isEmpty { await session.loadQuestions() }
        }
        .task(id: session.currentQuestion?.id) {
            await session.loadTranscriptIfNeeded()
            await session.loadFigures()
        }
        .onAppear { registerCommands() }
        .onDisappear { unregisterCommands() }
    }

    // MARK: Layout

    private func graphWidthRange(total: CGFloat) -> ClosedRange<CGFloat> {
        let available = total - StudyLayout.tutorWidth - StudyLayout.questionMinWidth - PaneDivider.thickness
        let upper = max(StudyLayout.graphMinWidth, available)
        return StudyLayout.graphMinWidth...upper
    }

    private func clampedGraphWidth(total: CGFloat) -> CGFloat {
        let range = graphWidthRange(total: total)
        return min(max(state.graphWidth, range.lowerBound), range.upperBound)
    }

    // MARK: Commands

    private func registerCommands() {
        unregisterCommands()
        let session = session
        commandTokens = [
            app.commands.register(.checkAnswers) {
                guard session.section == .study, session.currentInstance != nil else { return }
                Task { await session.checkAnswers() }
            },
            app.commands.register(.showHint) {
                guard session.section == .study else { return }
                session.askForHint()
            },
        ]
    }

    private func unregisterCommands() {
        for token in commandTokens { app.commands.unregister(token) }
        commandTokens = []
    }
}

/// Fixed widths of the Study layout.
enum StudyLayout {
    static let questionMinWidth: CGFloat = 420
    static let graphMinWidth: CGFloat = 380
    static let tutorWidth: CGFloat = 420
}

/// A draggable hairline between the question pane and the graph pane.
struct PaneDivider: View {
    static let thickness: CGFloat = 9

    @Environment(\.thubanTheme) private var theme
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>
    @State private var hovering = false
    @State private var startWidth: CGFloat?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Rectangle()
                .fill(hovering || startWidth != nil ? theme.accentColor : theme.lineColor)
                .frame(width: 1)
        }
        .frame(width: Self.thickness)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? width
                    startWidth = start
                    // The graph sits to the right: dragging left widens it.
                    width = min(max(start - value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startWidth = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize graph pane")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: width = min(width + 40, range.upperBound)
            case .decrement: width = max(width - 40, range.lowerBound)
            @unknown default: break
            }
        }
    }
}
