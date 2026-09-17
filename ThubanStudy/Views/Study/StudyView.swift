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
                    .frame(width: tutorWidth(total: geometry.size.width))
                    .thubanHairline(.leading, color: theme.lineColor)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottomTrailing) {
                if session.showCalculator {
                    CalculatorPanel(session: session)
                        .padding(.trailing, tutorWidth(total: geometry.size.width) + 16)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
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

    /// The tutor pane keeps its preferred width until the three panes no longer fit; below that it gives up
    /// width first (down to `tutorMinWidth`) so nothing is pushed off-screen at the 1100 pt window minimum.
    private func tutorWidth(total: CGFloat) -> CGFloat {
        guard session.showGraph else { return StudyLayout.tutorWidth }
        let needed = StudyLayout.questionMinWidth + PaneDivider.thickness + StudyLayout.graphMinWidth
            + StudyLayout.tutorWidth
        let deficit = max(0, needed - total)
        return max(StudyLayout.tutorMinWidth, StudyLayout.tutorWidth - deficit)
    }

    private func graphWidthRange(total: CGFloat) -> ClosedRange<CGFloat> {
        let available = total - tutorWidth(total: total) - StudyLayout.questionMinWidth - PaneDivider.thickness
        // When even a shrunken tutor pane leaves less than the preferred graph minimum, the graph takes what is
        // left (never below its hard floor) rather than overflowing the window.
        let lower = max(StudyLayout.graphFloorWidth, min(StudyLayout.graphMinWidth, available))
        let upper = max(lower, available)
        return lower...upper
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

/// Fixed widths of the Study layout. At the 1100 pt window minimum with the graph open, the tutor pane shrinks
/// to `tutorMinWidth` and the graph to whatever remains (≥ `graphFloorWidth`) so the layout never overflows.
enum StudyLayout {
    static let questionMinWidth: CGFloat = 420
    static let graphMinWidth: CGFloat = 380
    static let graphFloorWidth: CGFloat = 300
    static let tutorWidth: CGFloat = 420
    static let tutorMinWidth: CGFloat = 320
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
