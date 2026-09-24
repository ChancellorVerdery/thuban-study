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
            HStack(spacing: 0.z) {
                // The question pane takes exactly what the graph and tutor leave, so the row never overflows the
                // window (at a large app zoom its contents would otherwise push the panes off-screen).
                QuestionPane(session: session)
                    .frame(width: questionWidth(total: geometry.size.width), alignment: .leading)
                    .clipped()

                if session.showGraph {
                    PaneDivider(width: $state.graphWidth, range: graphWidthRange(total: geometry.size.width))
                    GraphPane(session: session)
                        .frame(width: clampedGraphWidth(total: geometry.size.width))
                        .clipped()
                        .thubanHairline(.leading, color: theme.lineColor)
                }

                PaneDivider(width: $state.tutorWidth, range: tutorWidthRange(total: geometry.size.width), label: "Resize tutor pane")
                TutorPane(session: session)
                    .frame(width: tutorWidth(total: geometry.size.width))
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottomTrailing) {
                if session.showCalculator {
                    CalculatorPanel(session: session)
                        .padding(.trailing, tutorWidth(total: geometry.size.width) + 16)
                        .padding(.bottom, 16.z)
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
            await session.loadFigures()
        }
        // A regenerated question starts a new thread (one per set of numbers).
        .task(id: session.currentThread) {
            await session.loadTranscriptIfNeeded()
        }
        .onAppear { registerCommands() }
        .onDisappear { unregisterCommands() }
    }

    // MARK: Layout

    /// How wide the tutor pane may be dragged: at least `tutorMinWidth`, and never so wide that the question pane
    /// (and the graph, when it is open) drop below their minimums.
    /// The question pane's minimum grows with the app zoom (its text does), up to 55 % of the window.
    private func questionMin(total: CGFloat) -> CGFloat {
        min(StudyLayout.questionMinWidth * AppZoom.shared.scale, total * 0.55)
    }

    private func tutorWidthRange(total: CGFloat) -> ClosedRange<CGFloat> {
        var others = questionMin(total: total) + PaneDivider.thickness
        if session.showGraph { others += PaneDivider.thickness + min(StudyLayout.graphFloorWidth, total * 0.2) }
        let upper = max(StudyLayout.tutorMinWidth, total - others)
        return StudyLayout.tutorMinWidth...upper
    }

    /// The tutor pane keeps the width the student dragged it to (the design width by default) until the panes no
    /// longer fit; below that it gives up width first (down to `tutorMinWidth`) so nothing is pushed off-screen.
    private func tutorWidth(total: CGFloat) -> CGFloat {
        let range = tutorWidthRange(total: total)
        var preferred = min(max(state.tutorWidth, range.lowerBound), range.upperBound)
        if session.showGraph {
            let needed = questionMin(total: total) + 2 * PaneDivider.thickness + StudyLayout.graphMinWidth + preferred
            preferred = max(StudyLayout.tutorMinWidth, preferred - max(0, needed - total))
        }
        return preferred
    }

    private func questionWidth(total: CGFloat) -> CGFloat {
        var others = PaneDivider.thickness + tutorWidth(total: total)
        if session.showGraph { others += PaneDivider.thickness + clampedGraphWidth(total: total) }
        return max(0, total - others)
    }

    private func graphWidthRange(total: CGFloat) -> ClosedRange<CGFloat> {
        let available = total - tutorWidth(total: total) - questionMin(total: total) - 2 * PaneDivider.thickness
        // When even a shrunken tutor pane leaves less than the preferred graph minimum, the graph takes what is
        // left rather than overflowing the window.
        let lower = max(0, min(StudyLayout.graphMinWidth, available))
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

/// A draggable hairline on the leading edge of a pane to its right (the graph, the tutor): dragging left widens it.
struct PaneDivider: View {
    static let thickness: CGFloat = 9

    @Environment(\.thubanTheme) private var theme
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>
    var label: String = "Resize graph pane"
    @State private var hovering = false
    @State private var startWidth: CGFloat?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Rectangle()
                .fill(hovering || startWidth != nil ? theme.accentColor : theme.lineColor)
                .frame(width: 1.z)
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
        .accessibilityLabel(label)
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
