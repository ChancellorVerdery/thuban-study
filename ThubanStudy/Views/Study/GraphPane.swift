import SwiftUI
import ThubanCore

/// Middle pane: Desmos 2D/3D grapher with the mode switch, reset, the "Tutor is editing" chip and close.
/// User edits inside Desmos flow into `session.graphExpressions`; tutor edits reach the page through the controller.
struct GraphPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Bindable var session: ClassSession

    /// Re-evaluates `tutorEditedRecently` while the chip is showing.
    @State private var chipTick = 0
    @State private var controller: GraphWebView.Controller?

    private var state: StudyState { session.studyState }

    var body: some View {
        VStack(spacing: 0) {
            header
            if app.hasDesmosKey, let controller {
                GraphWebView(controller: controller)
                    .overlay(alignment: .bottom) {
                        if let error = controller.lastError {
                            errorBanner(error)
                        }
                    }
            } else {
                missingKeyNotice
            }
        }
        .background(theme.panelColor)
        .onAppear { attach() }
        .onChange(of: app.desmosKey) { _, key in
            controller?.configure(desmosKey: key)
        }
        .onChange(of: session.graphMode) { _, mode in
            controller?.setMode(mode)
        }
        .onChange(of: session.tutorEditedAt) { _, _ in
            scheduleChipRefresh()
        }
    }

    // MARK: Wiring

    private func attach() {
        let controller = state.graphController(desmosKey: app.desmosKey, mode: session.graphMode)
        if controller.mode != session.graphMode { controller.setMode(session.graphMode) }
        let session = session
        controller.onReady = { [weak controller] in
            guard let controller else { return }
            controller.setMode(session.graphMode)
            controller.setExpressions(session.graphExpressions)
        }
        controller.onExpressionsChanged = { rows in
            Self.merge(rows: rows, into: session)
        }
        controller.onError = { message in
            ClassSession.logger.error("graph: \(message, privacy: .public)")
        }
        if controller.isPageReady {
            controller.setExpressions(session.graphExpressions)
        }
        self.controller = controller
        scheduleChipRefresh()
    }

    /// Applies the page's expression list to the session: keeps tutor styling on rows the tutor added, updates
    /// edited LaTeX, adds new rows as user rows and drops deleted ones.
    static func merge(rows: [(id: String, latex: String)], into session: ClassSession) {
        var next: [GraphExpression] = []
        let existing = Dictionary(session.graphExpressions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if var known = existing[row.id] {
                known.latex = row.latex
                next.append(known)
            } else if !row.latex.trimmingCharacters(in: .whitespaces).isEmpty {
                next.append(GraphExpression(id: row.id, latex: row.latex))
            }
        }
        if next != session.graphExpressions {
            session.graphExpressions = next
        }
    }

    private func scheduleChipRefresh() {
        guard session.tutorEditedRecently else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.1))
            chipTick += 1
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Icon(.graph2D, size: 18)
                .foregroundStyle(theme.brassInkColor)
            // The title is the only thing allowed to shrink when the pane is narrow; controls keep their labels.
            Text("Graph")
                .font(ThubanFont.display(16))
                .foregroundStyle(theme.inkColor)
                .lineLimit(1)
                .layoutPriority(-1)
            SegmentedPicker(selection: $session.graphMode, options: [
                SegmentOption(.twoD, "2D", icon: .graph2D),
                SegmentOption(.threeD, "3D", icon: .graph3D),
            ], segmentHeight: 24)
                .fixedSize()
            if session.tutorEditedRecently {
                Chip("Tutor is editing", kind: .accent, dot: true)
                    .fixedSize()
                    .id(chipTick)
                    .transition(.opacity)
            }
            Spacer(minLength: 4)
            Button("Reset view") { controller?.resetView() }
                .buttonStyle(GhostButtonStyle(height: 28, horizontalPadding: 8))
                .fixedSize()
                .disabled(controller == nil || !app.hasDesmosKey)
            IconButton(glyph: .close, label: "Close graph", size: 28, iconSize: 14) {
                session.showGraph = false
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ThubanMetrics.sectionBarHeight)
        .thubanHairline(.bottom, color: theme.lineColor)
        .animation(.easeInOut(duration: 0.15), value: session.tutorEditedRecently)
    }

    // MARK: Notices

    private var missingKeyNotice: some View {
        VStack(spacing: 10) {
            Icon(.graph2D, size: 26)
                .foregroundStyle(theme.brassInkColor)
            Text("The grapher needs a Desmos API key")
                .font(ThubanFont.display(18))
                .foregroundStyle(theme.inkColor)
            Text("Add your key under Settings › Grapher. The tutor's graph tools and the figure previews use it too.")
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Settings › Grapher") { openWindow(id: "settings") }
                .buttonStyle(.thubanSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(ThubanFont.small)
            .foregroundStyle(theme.negTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.negSoftColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            .padding(12)
            .accessibilityLabel("Graph error: \(message)")
    }
}
