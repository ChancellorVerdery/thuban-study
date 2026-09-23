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
        VStack(spacing: 0.z) {
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
            guard let controller else { return }
            controller.setMode(mode)
            // The page rebuilds the target calculator from its own per-mode list, which is empty after a page
            // reload; the session's rows for that mode are the source of truth.
            Self.pushCurrentMode(to: controller, from: session)
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
            Self.pushCurrentMode(to: controller, from: session)
        }
        controller.onExpressionsChanged = { rows, mode in
            Self.merge(rows: rows, mode: mode, into: session)
        }
        controller.onError = { message in
            ClassSession.logger.error("graph: \(message, privacy: .public)")
        }
        if controller.isPageReady {
            Self.pushCurrentMode(to: controller, from: session)
        }
        self.controller = controller
        scheduleChipRefresh()
    }

    /// Sends the rows of the mode on screen (the page keeps the other mode's own list) and then the tutor's pending
    /// viewport.
    private static func pushCurrentMode(to controller: GraphWebView.Controller, from session: ClassSession) {
        controller.setExpressions(session.visibleGraphExpressions)
        if session.graphMode == .twoD, let viewport = session.graphViewport {
            controller.setViewport(viewport)
        }
    }

    /// Applies the page's expression list for one mode to the session: keeps tutor styling on rows the tutor added,
    /// updates edited LaTeX, adds new rows as user rows and drops deleted ones. Rows of the other mode are kept as
    /// they are — Desmos only reports the calculator that is on screen.
    static func merge(rows: [(id: String, latex: String)], mode: GraphMode, into session: ClassSession) {
        var next: [GraphExpression] = session.graphExpressions.filter { $0.mode != mode }
        let existing = Dictionary(session.graphExpressions.filter { $0.mode == mode }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if var known = existing[row.id] {
                known.latex = row.latex
                next.append(known)
            } else if !row.latex.trimmingCharacters(in: .whitespaces).isEmpty {
                next.append(GraphExpression(id: row.id, latex: row.latex, mode: mode))
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

    /// Four tiers as the pane narrows (down to 300 pt beside the tutor): the labelled "Reset view" button; then an
    /// icon reset button; then the title goes and the tutor chip shortens; finally the chip is just its dot.
    /// The close button is never squeezed.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(title: true, chipText: "Tutor is editing", resetIcon: false)
            headerRow(title: true, chipText: "Tutor is editing", resetIcon: true)
            headerRow(title: false, chipText: "Editing", resetIcon: true)
            headerRow(title: false, chipText: nil, resetIcon: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12.z)
        .frame(height: ThubanMetrics.sectionBarHeight)
        .thubanHairline(.bottom, color: theme.lineColor)
        .animation(.easeInOut(duration: 0.15), value: session.tutorEditedRecently)
    }

    private func headerRow(title: Bool, chipText: String?, resetIcon: Bool) -> some View {
        HStack(spacing: title ? 10 : 8) {
            Icon(.graph2D, size: 18)
                .foregroundStyle(theme.brassInkColor)
            if title {
                Text("Graph")
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            SegmentedPicker(selection: $session.graphMode, options: [
                SegmentOption(.twoD, "2D", icon: .graph2D),
                SegmentOption(.threeD, "3D", icon: .graph3D),
            ], segmentHeight: 24)
                .fixedSize()
            if session.tutorEditedRecently {
                Group {
                    if let chipText {
                        Chip(chipText, kind: .accent, dot: true)
                    } else {
                        Circle()
                            .fill(theme.brassInkColor)
                            .frame(width: 8.z, height: 8.z)
                            .help("Tutor is editing")
                    }
                }
                .fixedSize()
                .id(chipTick)
                .transition(.opacity)
                .accessibilityLabel("Tutor is editing")
            }
            Spacer(minLength: 4)
            if resetIcon {
                IconButton(glyph: .reset, label: "Reset view", size: 28, iconSize: 15, action: resetView)
                    .disabled(!canResetView)
            } else {
                Button("Reset view", action: resetView)
                    .buttonStyle(GhostButtonStyle(height: 28, horizontalPadding: 8))
                    .fixedSize()
                    .disabled(!canResetView)
            }
            IconButton(glyph: .close, label: "Close graph", size: 28, iconSize: 14) {
                session.showGraph = false
            }
        }
    }

    private var canResetView: Bool { controller != nil && app.hasDesmosKey }

    private func resetView() {
        session.graphViewport = nil
        controller?.resetView()
    }

    // MARK: Notices

    private var missingKeyNotice: some View {
        VStack(spacing: 10.z) {
            Icon(.graph2D, size: 26)
                .foregroundStyle(theme.brassInkColor)
            Text("The grapher needs a Desmos API key")
                .font(ThubanFont.display(18))
                .foregroundStyle(theme.inkColor)
            Text("Add your key under Settings › Grapher. The tutor's graph tools and the figure previews use it too.")
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320.z)
            Button("Open Settings › Grapher") { openWindow(id: "settings") }
                .buttonStyle(.thubanSecondary)
        }
        .padding(24.z)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(ThubanFont.small)
            .foregroundStyle(theme.negTextColor)
            .padding(.horizontal, 10.z)
            .padding(.vertical, 6.z)
            .background(theme.negSoftColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            .padding(12.z)
            .accessibilityLabel("Graph error: \(message)")
    }
}
