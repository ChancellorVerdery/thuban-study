import Foundation
import Observation
internal import GraphModel
internal import GraphTypes
internal import ThubanGraphKit

/// One class's graphs (STUDY_INTEGRATION.md §5): a 2D and a 3D `GraphEmbedSession`, each with its own rows,
/// viewport and camera (switching modes is instant and loses nothing), both on the app's one Graph engine (each on
/// its own `MathEngineClient` lane), plus the class's Scientific calculator. The sessions are the only source of
/// truth; `rows` is a read-only projection for the tutor context and `get_student_work`.
@MainActor
@Observable
public final class StudyGraphHost {
    let twoD: GraphEmbedSession
    let threeD: GraphEmbedSession

    /// The mode on screen. The class session keeps it in step with its saved `graphMode` (`onModeChange`).
    public var mode: StudyGraphMode {
        didSet {
            guard mode != oldValue else { return }
            onModeChange?(mode)
        }
    }
    /// Ids of rows the tutor added (either mode); pruned when those rows are deleted (and restored with them by an
    /// undo or redo, see `retiredTutorIDs`).
    public internal(set) var tutorIDs: Set<String> = []
    /// The saved graphs have been read into the sessions (or there were none). Until then the pane shows no list,
    /// so nothing the student types can be replaced by the load.
    public private(set) var isLoaded = true
    /// When the tutor last changed the graph (the "Tutor is editing" chip shows for 5 s).
    public internal(set) var tutorEditedAt: Date?
    /// Bumped on every committed change of either document (drives `rows` observers and persistence).
    public private(set) var revision = 0

    /// The list's narrowest width: short rows (`x=-2`, `(0,-0.25)`), the blank row's placeholder, the list header and
    /// its viewport footer fit whole from here.
    public static let listMinimumWidth: CGFloat = 240
    /// Pane width below which the expression list starts hidden, leaving the graph the room (the list gets
    /// `listMinimumWidth` or more from here on).
    public static let listMinimumPaneWidth: CGFloat = 640
    /// The student's choice to show or hide the expression list; nil = by the pane's width.
    public var listPreference: Bool?
    /// The graph pane's width, reported by `StudyGraphView`.
    public internal(set) var paneWidth: CGFloat = 0
    /// Whether the expression list is on screen.
    public var isListShown: Bool { listPreference ?? (paneWidth >= Self.listMinimumPaneWidth) }
    /// The pane's list button.
    public func toggleList() { listPreference = !isListShown }

    /// The width the 3D view's overlays (View card, legend, the rotate / pan / zoom hint) need at zoom 1.
    static let threeDOverlayWidth: CGFloat = 520
    /// The list's width for a pane `width` wide (before zoom).
    static func listWidth(forPane width: CGFloat) -> CGFloat { min(300, max(listMinimumWidth, width * 0.38)) }

    /// The zoom to draw the graph views at, given the app's zoom: the app zoom, except that in 3D a graph area
    /// narrower than the overlays need scales them down to fit (not below 60 %), instead of clipping them.
    public func graphZoom(appZoom: CGFloat) -> CGFloat {
        guard mode == .threeD, paneWidth > 0 else { return appZoom }
        let area = paneWidth - (isListShown ? Self.listWidth(forPane: paneWidth) + 1 : 0)
        let fit = area / (Self.threeDOverlayWidth * appZoom)
        return appZoom * min(1, max(0.6, fit))
    }

    /// Called after any change worth saving (documents, tutor ids). Persistence (`StudyGraphStore`) debounces it.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// The mode changed (by the pane's picker or `show_graph`).
    @ObservationIgnored public var onModeChange: ((StudyGraphMode) -> Void)?
    /// `show_graph` / `hide_graph` / an edit by the tutor wants the pane open (true) or closed (false).
    @ObservationIgnored public var onShowGraph: ((Bool) -> Void)?

    @ObservationIgnored let engine: StudyGraphEngine?
    @ObservationIgnored private var calculatorController: ScientificCalculatorController?
    /// Row ids per session as last seen, to tell a row the user just added from an edited one.
    @ObservationIgnored private var knownIDs: [StudyGraphMode: Set<ExpressionID>] = [:]
    /// Every row id each session has held since its document was last replaced: a row that comes back with one of
    /// these ids was restored by undo / redo, not newly created.
    @ObservationIgnored private var seenIDs: [StudyGraphMode: Set<ExpressionID>] = [:]
    /// Tutor rows that were removed (by the tutor or the student). Undo / redo can bring them back; they are then the
    /// tutor's again (same color, same `fromTutor`).
    @ObservationIgnored private var retiredTutorIDs: Set<String> = []
    @ObservationIgnored var persistence: StudyGraphStore? {
        didSet { isLoaded = persistence == nil }
    }
    @ObservationIgnored private var isRestoring = false

    /// `engine` nil runs headless (tests): commands, undo and change reporting work, nothing is analysed or drawn.
    public init(engine: StudyGraphEngine?, mode: StudyGraphMode = .twoD) {
        self.engine = engine
        self.mode = mode
        twoD = GraphEmbedSession(document: Self.emptyDocument(.twoD), engine: engine?.graphEngine)
        threeD = GraphEmbedSession(document: Self.emptyDocument(.threeD), engine: engine?.graphEngine)
        knownIDs = [.twoD: Set(twoD.document.items.map(\.id)), .threeD: Set(threeD.document.items.map(\.id))]
        seenIDs = knownIDs
        twoD.onDocumentChange = { [weak self] document, origin in self?.documentChanged(.twoD, document, origin) }
        threeD.onDocumentChange = { [weak self] document, origin in self?.documentChanged(.threeD, document, origin) }
        engine?.warmUp()
    }

    /// A fresh graph for `mode`: one blank row to type into, the standard view.
    nonisolated static func emptyDocument(_ mode: StudyGraphMode) -> GraphDocument {
        var document = GraphDocument.empty()
        document.mode = mode == .threeD ? .threeD : .twoD
        return document
    }

    func session(_ mode: StudyGraphMode) -> GraphEmbedSession { mode == .twoD ? twoD : threeD }
    var current: GraphEmbedSession { session(mode) }

    /// The graph engine could not start (the pane's banner and the tools' refusal).
    public var engineError: String? { engine?.startupError }

    // MARK: - Projection

    /// Every non-empty expression row of both modes, 2D first, in list order.
    public var rows: [StudyGraphRow] {
        _ = revision
        return StudyGraphMode.allCases.flatMap { mode in
            session(mode).document.items.compactMap { item -> StudyGraphRow? in
                guard item.kind == .expression else { return nil }
                let latex = item.latex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latex.isEmpty else { return nil }
                return StudyGraphRow(id: item.id.rawValue, latex: latex, mode: mode,
                                     fromTutor: tutorIDs.contains(item.id.rawValue), hidden: item.isHidden)
            }
        }
    }

    /// The LaTeX of the shown rows of the mode on screen, in list order ("On the graph now", `get_student_work`).
    public var visibleLatex: [String] {
        _ = revision
        return current.visibleExpressionLatex()
    }

    /// Non-empty expression rows in `mode` (hidden ones included): the tools' `count`.
    public func rowCount(_ mode: StudyGraphMode) -> Int {
        session(mode).document.items.filter { $0.kind == .expression && !$0.latex.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    public var tutorEditedRecently: Bool {
        guard let tutorEditedAt else { return false }
        return Date().timeIntervalSince(tutorEditedAt) < 5
    }

    // MARK: - Actions

    /// Home view of the mode on screen (2D the standard view with equal axes, 3D the default camera). Equal axes come
    /// back too: `graph_set_viewport` turns them off to show the tutor's exact bounds, and Study has no other
    /// control for them.
    public func resetView() {
        let embed = current
        let settings = embed.document.settings
        if mode == .twoD, !settings.equalAxes, !settings.lockViewport {
            var restored = settings
            restored.equalAxes = true
            embed.perform(.batch([.setSettings(restored), .setViewport(Viewport2D.standard)]), origin: .host)
            return
        }
        embed.resetView()
    }

    /// The class's Scientific calculator (created on first use, on the shared engine). Nil when headless.
    var calculator: ScientificCalculatorController? {
        if let calculatorController { return calculatorController }
        guard let engine else { return nil }
        let controller = ScientificCalculatorController(engine: engine.calculatorEngine)
        // Study's classes work in radians (as the Desmos calculator did); the page's DEG | RAD switch changes it.
        var state = controller.session.document.calculators.scientific
        state.angleUnit = .radians
        controller.session.performTransient(.setScientific(state))
        calculatorController = controller
        return controller
    }

    /// Puts `latex` into the list's blank row of `mode` (a new row when there is none), as the student typing it
    /// (smoke, tests).
    public func typeIntoBlankRow(_ latex: String, mode: StudyGraphMode) {
        let embed = session(mode)
        if let blank = embed.document.items.first(where: StudyGraphTools.isBlank) {
            embed.perform(.setLatex(blank.id, latex), origin: .user)
        } else {
            embed.perform(.addItem(embed.session.newItem(latex: latex), after: embed.document.items.last?.id), origin: .user)
        }
    }

    /// Analyses both modes now (smoke, tests with an engine).
    public func analyzeNow() async {
        await twoD.session.analyzeNow()
        await threeD.session.analyzeNow()
    }

    func stampTutorEdit() {
        tutorEditedAt = Date()
    }

    func markTutor(_ id: String) {
        retiredTutorIDs.remove(id)
        guard !tutorIDs.contains(id) else { return }
        tutorIDs.insert(id)
        changed()
    }

    func unmarkTutor(_ id: String) {
        guard tutorIDs.contains(id), !holds(id) else { return }
        tutorIDs.remove(id)
        retiredTutorIDs.insert(id)
        changed()
    }

    /// Either session has a row with this id.
    func holds(_ id: String) -> Bool {
        twoD.document.item(ExpressionID(id)) != nil || threeD.document.item(ExpressionID(id)) != nil
    }

    /// Called by persistence once the saved graphs are read.
    func loadFinished() {
        isLoaded = true
    }

    // MARK: - Documents

    /// Replaces both documents and the tutor ids (a class's saved graph was read). Clears undo.
    func restore(twoD document2D: GraphDocument, threeD document3D: GraphDocument, tutorIDs ids: Set<String>) {
        var two = document2D, three = document3D
        two.mode = .twoD
        three.mode = .threeD
        isRestoring = true
        knownIDs = [.twoD: Set(two.items.map(\.id)), .threeD: Set(three.items.map(\.id))]
        seenIDs = knownIDs
        retiredTutorIDs = []
        twoD.replaceDocument(two, origin: .host)
        threeD.replaceDocument(three, origin: .host)
        isRestoring = false
        tutorIDs = ids.filter { two.item(ExpressionID($0)) != nil || three.item(ExpressionID($0)) != nil }
        revision += 1
        onChange?()
    }

    private func documentChanged(_ mode: StudyGraphMode, _ document: GraphDocument, _ origin: GraphEmbedSession.Origin) {
        guard !isRestoring else { return }
        let ids = Set(document.items.map(\.id))
        let previous = knownIDs[mode] ?? []
        let seen = seenIDs[mode] ?? []
        knownIDs[mode] = ids
        seenIDs[mode] = seen.union(ids)
        let added = ids.subtracting(previous)
        // Rows brought back by undo / redo keep their owner: a returning tutor row is the tutor's again.
        let returning = added.intersection(seen)
        var owners = tutorIDs
        for id in returning where retiredTutorIDs.contains(id.rawValue) {
            owners.insert(id.rawValue)
            retiredTutorIDs.remove(id.rawValue)
        }
        // A tutor row that is gone (deleted, or undone) is no longer the tutor's until it comes back.
        let other = session(mode == .twoD ? .threeD : .twoD).document
        let live = owners.filter { ids.contains(ExpressionID($0)) || other.item(ExpressionID($0)) != nil }
        retiredTutorIDs.formUnion(owners.subtracting(live))
        if live != tutorIDs { tutorIDs = live }
        if origin == .user {
            // Only rows created just now take the accent; restored rows keep the color they had.
            recolorNewUserRows(in: mode, document: document, added: added.subtracting(seen))
        }
        changed()
    }

    /// Rows the student adds in the list take the theme accent (series 0), not the next automatic series color, so
    /// user rows always read apart from the tutor's (signal) rows. Transient: the add stays one undo step.
    private func recolorNewUserRows(in mode: StudyGraphMode, document: GraphDocument, added: Set<ExpressionID>) {
        guard !added.isEmpty else { return }
        let commands: [DocumentCommand] = document.items.compactMap { item in
            guard added.contains(item.id), item.isGraphable, !tutorIDs.contains(item.id.rawValue),
                  item.color != .brass, SeriesColor.presets.contains(item.color) else { return nil }
            return .setColor(item.id, .brass)
        }
        guard !commands.isEmpty else { return }
        session(mode).session.performTransient(.batch(commands))
    }

    private func changed() {
        revision += 1
        onChange?()
        persistence?.scheduleSave()
    }
}
