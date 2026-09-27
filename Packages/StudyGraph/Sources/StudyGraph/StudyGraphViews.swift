import SwiftUI
import ThubanCore
internal import GraphTheme
internal import ThubanGraphKit

// MARK: - Theme bridge (STUDY_INTEGRATION.md §8)

extension GraphKitTheme {
    /// Study's resolved scheme as the kit's theme: a field copy (Study and Graph ship the same Atlas schemes and the
    /// same token set). `paper` draws the graph paper from other tokens (reverse contrast).
    init(study theme: ThubanCore.ResolvedTheme, paper: ThubanCore.ResolvedTheme? = nil, textScale: CGFloat = 1, zoom: CGFloat = 1) {
        self.init(theme: Self.bridge(theme), paperTheme: paper.map(Self.bridge), textScale: textScale, zoom: zoom)
    }

    /// The field copy. Graph adds two tokens Study does not have (`accentStrong`, `track`): for a preset scheme whose
    /// shared tokens match Graph's own resolution exactly, they are taken from it; otherwise Graph's defaults apply
    /// (accentText, panel2).
    static func bridge(_ t: ThubanCore.ResolvedTheme) -> GraphTheme.ResolvedTheme {
        var bridged = GraphTheme.ResolvedTheme(
            bg: t.bg, panel: t.panel, panel2: t.panel2, line: t.line, line2: t.line2,
            ink: t.ink, inkDim: t.inkDim, inkFaint: t.inkFaint, accent: t.accent, accentText: t.accentText,
            accentDeep: t.accentDeep, accentTint: t.accentTint, onAccent: t.onAccent, signal: t.signal,
            signalText: t.signalText, pos: t.pos, posText: t.posText, neg: t.neg, negText: t.negText,
            posSoft: t.posSoft, negSoft: t.negSoft, warnSoft: t.warnSoft, signalSoft: t.signalSoft,
            isDark: t.isDark, inkRGB: t.inkRGB, accentRGB: t.accentRGB, schemeId: t.schemeId)
        if GraphTheme.SchemePresets.all.contains(where: { $0.id == t.schemeId }) {
            let own = GraphTheme.ThemeResolver.resolve(
                GraphTheme.ThemeSelection(mode: t.isDark ? .dark : .light, schemeId: t.schemeId, custom: nil),
                systemIsDark: t.isDark)
            var comparable = own
            comparable.accentStrong = bridged.accentStrong
            comparable.track = bridged.track
            if comparable == bridged {
                bridged.accentStrong = own.accentStrong
                bridged.track = own.track
            }
        }
        return bridged
    }
}

extension View {
    /// Themes the graph and calculator views below from Study's resolved scheme; a scheme change is a plain
    /// environment update (no reload). `paper` (reverse contrast) draws the graph paper from the opposite mode.
    public func studyGraphTheme(_ theme: ThubanCore.ResolvedTheme, paper: ThubanCore.ResolvedTheme? = nil, zoom: CGFloat = 1) -> some View {
        graphKitTheme(GraphKitTheme(study: theme, paper: paper, zoom: zoom))
    }
}

// MARK: - Views

/// The graph pane's body: the mode on screen's graph (2D canvas or Metal 3D) with the kit's MathLive expression
/// list beside it. Study owns the 2D | 3D switch (one session per mode), so the kit's mode control is off, the
/// keypad starts hidden (Control-K in the list shows it) and table drops are ignored.
public struct StudyGraphView: View {
    let host: StudyGraphHost
    /// This pane's zoom (`studyGraphTheme(zoom:)`); the kit multiplies `listWidth` by it.
    @Environment(\.thubanZoom) private var zoom

    public init(host: StudyGraphHost) {
        self.host = host
    }

    public var body: some View {
        GeometryReader { proxy in
            GraphEmbedView(session: host.current, configuration: configuration(width: proxy.size.width))
                .id(host.mode)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)   // the 3D view's overlays can ask for more width than a narrow pane has: the list stays whole, the graph is clipped on the right
                .clipped()
                .onAppear { host.paneWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in host.paneWidth = width }
        }
    }

    /// The list takes about 38 % of the pane, never under `StudyGraphHost.listMinimumWidth` (narrower, rows,
    /// placeholders and the list's footer truncate) nor over 300 pt; below `StudyGraphHost.listMinimumPaneWidth` it
    /// starts hidden (the pane's list button shows it).
    private func configuration(width: CGFloat) -> GraphEmbedConfiguration {
        var configuration = GraphEmbedConfiguration()
        configuration.showsExpressionList = host.listPreference ?? (width >= StudyGraphHost.listMinimumPaneWidth)
        configuration.listWidth = (StudyGraphHost.listWidth(forPane: width) / max(0.5, zoom)).rounded()
        configuration.showsKeypad = false
        configuration.showsModeControls = false
        configuration.onDropTables = nil
        return configuration
    }
}

/// The class's Scientific calculator (the kit's page, evaluated by the Graph engine). `onInsert` adds an "Insert"
/// action to each result (Study: into the focused answer field).
public struct StudyCalculatorView: View {
    let host: StudyGraphHost
    let onInsert: (@MainActor (String) -> Void)?

    public init(host: StudyGraphHost, onInsert: (@MainActor (String) -> Void)? = nil) {
        self.host = host
        self.onInsert = onInsert
    }

    public var body: some View {
        if let calculator = host.calculator {
            ScientificCalculatorView(controller: calculator, onInsert: onInsert)
        } else {
            Color.clear
        }
    }
}

extension StudyGraphHost {
    /// Evaluates `latex` in the class's calculator as if typed and entered (smoke). Returns the result's LaTeX.
    @discardableResult
    public func submitToCalculator(_ latex: String) async -> String? {
        guard let calculator else { return nil }
        let result = await calculator.submit(latex)
        return result.latex
    }

    /// Entries in the calculator's history (smoke).
    public var calculatorHistoryCount: Int { calculator?.history.count ?? 0 }
}
