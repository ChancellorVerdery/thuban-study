import AppKit
import SwiftUI
import ThubanCore
import os

// MARK: - Model

/// The figures under review (one document, or every document of the class), the current index and the
/// persistence of accept / keep original / skip and edited series through `Store`'s `FigureRepository`.
@MainActor
@Observable
final class FigureReviewModel {
    private static let logger = Logger(subsystem: "com.thuban.study", category: "figures")

    enum Scope: Equatable {
        case document(ImportedDocument)
        case classWide
    }

    let scope: Scope
    @ObservationIgnored private let session: ClassSession

    private(set) var figures: [Figure] = []
    private(set) var documentsById: [DocumentID: ImportedDocument] = [:]
    private(set) var index = 0
    private(set) var isLoading = false
    var error: String?
    var isEditingValues = false

    init(session: ClassSession, scope: Scope) {
        self.session = session
        self.scope = scope
    }

    var current: Figure? { figures.indices.contains(index) ? figures[index] : nil }
    var count: Int { figures.count }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < figures.count }

    var scopeTitle: String {
        switch scope {
        case .document(let document): return document.filename
        case .classWide: return session.studyClass?.name ?? "Figures"
        }
    }

    func document(for figure: Figure) -> ImportedDocument? { figure.documentId.flatMap { documentsById[$0] } }

    /// Original PNG of a figure (nil when the file is missing).
    func image(for figure: Figure) -> NSImage? {
        NSImage(contentsOf: AppPaths.figureURL(figure.originalPath))
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if session.importQueue.isEmpty { await session.loadDocuments() }
        documentsById = Dictionary(session.importQueue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            switch scope {
            case .document(let document):
                figures = try await session.store.figures(for: document.id)
            case .classWide:
                figures = try await session.store.figures(in: session.classId)
            }
            // Start at the first figure that still needs a decision (or where the caller asked).
            index = figures.firstIndex { $0.status == .reviewing || $0.status == .pending } ?? 0
            if let requested = session.pendingFigureReviewIndex {
                session.pendingFigureReviewIndex = nil
                if figures.indices.contains(requested) { index = requested }
            }
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("Figures failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Navigation

    func next() { if canGoForward { index += 1 } }
    func previous() { if canGoBack { index -= 1 } }
    func jump(to id: FigureID) {
        if let target = figures.firstIndex(where: { $0.id == id }) { index = target }
    }

    // MARK: Decisions

    /// Persists a status for the current figure and moves on to the next one.
    func decide(_ status: FigureStatus) async {
        guard var figure = current else { return }
        figure.status = status
        await persist(figure)
        next()
    }

    /// Replaces the chart's series (from the values editor) and keeps the figure in review.
    func saveChart(_ chart: StandardChart) async {
        guard var figure = current else { return }
        figure.chart = chart
        figure.kind = .chart
        if figure.status == .pending { figure.status = .reviewing }
        await persist(figure)
    }

    private func persist(_ figure: Figure) async {
        do {
            try await session.store.update(figure)
            if let position = figures.firstIndex(where: { $0.id == figure.id }) {
                figures[position] = figure
            }
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("Figure update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Chart → Desmos (see ChartRenderer)

    nonisolated static func expressions(for chart: StandardChart, theme: ResolvedTheme) -> [GraphExpression] {
        ChartRenderer.expressions(for: chart, theme: theme)
    }

    nonisolated static func viewport(for chart: StandardChart) -> GraphViewport? {
        ChartRenderer.viewport(for: chart)
    }

    nonisolated static func format(_ value: Double) -> String { ChartGeometry.number(value) }
}

// MARK: - View

/// Figure review: breadcrumb, original PNG beside the standardized Desmos rendering, the extracted series
/// with an editor, detection chips, accept / keep original / skip, a pager, and a rail of the document's figures.
struct FigureReviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var session: ClassSession
    var breadcrumbRoot: String
    var onClose: () -> Void

    @State private var model: FigureReviewModel
    /// One grapher for the pane's lifetime; the Desmos key is applied from the environment on appear.
    @State private var graph = GraphWebView.Controller(desmosKey: "", mode: .twoD, showsExpressions: false)

    init(session: ClassSession, scope: FigureReviewModel.Scope, breadcrumbRoot: String = "Import", onClose: @escaping () -> Void) {
        self.session = session
        self.breadcrumbRoot = breadcrumbRoot
        self.onClose = onClose
        _model = State(initialValue: FigureReviewModel(session: session, scope: scope))
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            if model.isLoading, model.figures.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if let figure = model.current {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        FigureReviewPane(model: model, figure: figure, graph: graph)
                            .padding(.bottom, 20)
                    }
                    FigureRail(model: model)
                        .frame(width: 260)
                }
                .padding(.horizontal, 24)
            } else {
                EmptyState(icon: .figureClip, title: "No figures", message: "No figures were clipped from these documents.") {
                    Button("Back") { onClose() }
                        .buttonStyle(.thubanSecondary)
                }
            }
            if let error = model.error {
                Text(error)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.negTextColor)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
        .onAppear {
            graph.onReady = { [graph] in
                Task { @MainActor in Self.push(model: model, to: graph) }
            }
        }
        .onChange(of: app.desmosKey, initial: true) { _, key in graph.configure(desmosKey: key) }
        .onChange(of: model.current?.id, initial: true) { _, _ in pushChart() }
        .onChange(of: model.current?.chart) { _, _ in pushChart() }
        .sheet(isPresented: Binding(get: { model.isEditingValues }, set: { model.isEditingValues = $0 })) {
            if let chart = model.current?.chart {
                SeriesValuesSheet(chart: chart) { edited in
                    Task { await model.saveChart(edited) }
                }
                .environment(\.thubanTheme, theme)
            }
        }
    }

    private func pushChart() {
        Self.push(model: model, to: graph)
    }

    @MainActor
    private static func push(model: FigureReviewModel, to graph: GraphWebView.Controller) {
        guard let chart = model.current?.chart else {
            graph.clear()
            return
        }
        graph.setExpressions(FigureReviewModel.expressions(for: chart, theme: graph.theme))
        if let viewport = FigureReviewModel.viewport(for: chart) {
            graph.setViewport(viewport)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button(breadcrumbRoot) { onClose() }
                .buttonStyle(GhostButtonStyle(height: 28, tinted: true, horizontalPadding: 6))
                .keyboardShortcut(.cancelAction)
            Glyph(.chevronRight, size: 12).foregroundStyle(theme.inkFaintColor)
            Text("Figures")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
            Glyph(.chevronRight, size: 12).foregroundStyle(theme.inkFaintColor)
            Text(model.scopeTitle)
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if model.count > 0 {
                Text("Figure \(model.index + 1) of \(model.count)")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
                IconButton(glyph: .chevronLeft, label: "Previous figure", size: 28, iconSize: 14) { model.previous() }
                    .disabled(!model.canGoBack)
                    .opacity(model.canGoBack ? 1 : 0.4)
                IconButton(glyph: .chevronRight, label: "Next figure", size: 28, iconSize: 14) { model.next() }
                    .disabled(!model.canGoForward)
                    .opacity(model.canGoForward ? 1 : 0.4)
            }
        }
    }
}

// MARK: - Main pane

private struct FigureReviewPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var model: FigureReviewModel
    var figure: Figure
    var graph: GraphWebView.Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                originalPanel
                standardizedPanel
            }
            .frame(height: 360)
            if let chart = figure.chart {
                detectionChips(chart)
                SeriesTable(chart: chart) { model.isEditingValues = true }
            } else {
                Text(figure.kind == .unknown
                     ? "This figure has not been analysed yet. You can keep it as an image or skip it."
                     : "The agent classified this figure as a \(figure.kind.rawValue); only charts are standardized.")
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
    }

    private var originalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original (clipped from page \(figure.pageOrIndex))")
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            Group {
                if let image = model.image(for: figure) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .accessibilityLabel(figure.caption ?? "Original figure")
                } else {
                    Text("The clipped image is missing.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkFaintColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
            if let caption = figure.caption, !caption.isEmpty {
                Text(caption)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .thubanPanel(padding: 14)
    }

    private var standardizedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Standardized")
                    .font(ThubanFont.micro)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(theme.inkDimColor)
                Spacer()
                Chip("App graph style", kind: .accent, icon: .graph2D)
            }
            ZStack {
                if figure.chart != nil {
                    GraphWebView(controller: graph)
                        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                    if app.desmosKey.isEmpty {
                        Text("Add a Desmos API key in Settings to render the standardized graph.")
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.inkDimColor)
                            .padding(12)
                            .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                    }
                } else {
                    Text("Not a chart — nothing to standardize.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkFaintColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
            Text("Standardized with the app's graph style")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkFaintColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .thubanPanel(padding: 14)
    }

    private func detectionChips(_ chart: StandardChart) -> some View {
        HStack(spacing: 8) {
            Chip(chart.isSlopeField ? (chart.arrows ? "Direction field" : "Slope field") : chart.chartType.capitalized, kind: .accent)
            if chart.isSlopeField, let slope = chart.slope?.nilIfEmpty {
                Chip("dy/dx = \(slope)", kind: .neutral)
            }
            Chip("Axes: \(chart.xLabel?.nilIfEmpty ?? "x") / \(chart.yLabel?.nilIfEmpty ?? "y")", kind: .neutral)
            Chip("\(chart.series.count) series", kind: .neutral)
            Chip("Confidence \(Int((StandardChart.clampedConfidence(chart.confidence) * 100).rounded()))%", kind: chart.confidence >= 0.7 ? .pos : .warn)
            Spacer()
            FigureStatusChip(status: figure.status)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Accept standardized graph") { Task { await model.decide(.accepted) } }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(figure.chart == nil)
            Button("Keep original image") { Task { await model.decide(.keptOriginal) } }
                .buttonStyle(.thubanSecondary)
            Button("Skip figure") { Task { await model.decide(.skipped) } }
                .buttonStyle(.thubanGhost)
            Spacer()
        }
    }
}

/// Status chip for a figure.
struct FigureStatusChip: View {
    var status: FigureStatus

    var body: some View {
        switch status {
        case .pending: Chip("Pending", kind: .neutral)
        case .reviewing: Chip("Needs review", kind: .warn)
        case .accepted: Chip("Standardized", kind: .pos)
        case .keptOriginal: Chip("Original kept", kind: .signal)
        case .skipped: Chip("Skipped", kind: .neutral)
        }
    }
}

// MARK: - Series table

/// "Extracted series": one line per series with a preview of its values, and the Edit values button.
private struct SeriesTable: View {
    @Environment(\.thubanTheme) private var theme
    var chart: StandardChart
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Extracted series")
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
                Spacer()
                Button("Edit values", action: onEdit)
                    .buttonStyle(SecondaryButtonStyle(height: 28))
            }
            if chart.series.isEmpty {
                Text("The agent found no series in this chart.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(chart.series.enumerated()), id: \.offset) { offset, series in
                        HStack(alignment: .top, spacing: 12) {
                            Text(series.name.nilIfEmpty ?? "Series \(offset + 1)")
                                .font(ThubanFont.body(14, weight: .semibold))
                                .foregroundStyle(theme.inkColor)
                                .frame(width: 160, alignment: .leading)
                                .lineLimit(1)
                            Text(preview(series))
                                .font(ThubanFont.mono(12))
                                .foregroundStyle(theme.inkDimColor)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if offset < chart.series.count - 1 {
                            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                        }
                    }
                }
                .thubanPanel(padding: 0)
            }
        }
    }

    private func preview(_ series: ChartSeries) -> String {
        if let latex = series.latex, !latex.isEmpty { return "y = \(latex)" }
        let points = (series.points ?? []).filter { $0.count >= 2 }
        let shown = points.prefix(8).map { "(\(FigureReviewModel.format($0[0])), \(FigureReviewModel.format($0[1])))" }
        let more = points.count > 8 ? " … \(points.count) points" : ""
        return shown.joined(separator: "  ") + more
    }
}

// MARK: - Values editor

/// Editable grid of the series values (x / y text cells, add/remove rows, function latex for function series).
private struct SeriesValuesSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var onSave: (StandardChart) -> Void

    @State private var chart: StandardChart
    @State private var series: [SeriesDraft]
    @State private var problem: String?

    init(chart: StandardChart, onSave: @escaping (StandardChart) -> Void) {
        self.onSave = onSave
        _chart = State(initialValue: chart)
        _series = State(initialValue: chart.series.map(SeriesDraft.init))
    }

    var body: some View {
        ModalCard(title: "Edit series values", width: 620) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($series) { $draft in
                        SeriesDraftEditor(draft: $draft)
                    }
                    Button {
                        series.append(SeriesDraft(name: "Series \(series.count + 1)"))
                    } label: {
                        HStack(spacing: 6) { Glyph(.plus, size: 14); Text("Add series") }
                    }
                    .buttonStyle(.thubanGhostTinted)
                    if let problem {
                        Text(problem)
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.negTextColor)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 460)
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Save values") { save() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    private func save() {
        var result: [ChartSeries] = []
        for draft in series {
            if draft.isFunction {
                let latex = draft.latex.trimmingCharacters(in: .whitespaces)
                guard !latex.isEmpty else { problem = "“\(draft.name)” needs a function of x."; return }
                result.append(ChartSeries(name: draft.name, latex: latex, color: draft.color))
            } else {
                var points: [[Double]] = []
                for cell in draft.points {
                    let xText = cell.x.trimmingCharacters(in: .whitespaces)
                    let yText = cell.y.trimmingCharacters(in: .whitespaces)
                    if xText.isEmpty && yText.isEmpty { continue }
                    guard let x = Double(xText), let y = Double(yText) else {
                        problem = "“\(draft.name)” has a value that is not a number: (\(cell.x), \(cell.y))."
                        return
                    }
                    points.append([x, y])
                }
                result.append(ChartSeries(name: draft.name, points: points, color: draft.color))
            }
        }
        var edited = chart
        edited.series = result
        onSave(edited)
        dismiss()
    }
}

private struct SeriesDraft: Identifiable {
    struct Cell: Identifiable {
        let id = UUID()
        var x: String
        var y: String
    }

    let id = UUID()
    var name: String
    var isFunction: Bool
    var latex: String
    var points: [Cell]
    var color: String?

    init(name: String) {
        self.name = name
        isFunction = false
        latex = ""
        points = [Cell(x: "", y: "")]
        color = nil
    }

    init(_ series: ChartSeries) {
        name = series.name
        isFunction = !(series.latex ?? "").isEmpty
        latex = series.latex ?? ""
        points = (series.points ?? []).filter { $0.count >= 2 }.map {
            Cell(x: FigureReviewModel.format($0[0]), y: FigureReviewModel.format($0[1]))
        }
        if points.isEmpty { points = [Cell(x: "", y: "")] }
        color = series.color
    }
}

private struct SeriesDraftEditor: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var draft: SeriesDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Series name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Picker("Kind", selection: $draft.isFunction) {
                    Text("Points").tag(false)
                    Text("Function of x").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
            }
            if draft.isFunction {
                TextField("2x+1", text: $draft.latex)
                    .textFieldStyle(.roundedBorder)
                    .font(ThubanFont.mono(13))
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("x").font(ThubanFont.micro).foregroundStyle(theme.inkDimColor).frame(width: 120, alignment: .leading)
                        Text("y").font(ThubanFont.micro).foregroundStyle(theme.inkDimColor).frame(width: 120, alignment: .leading)
                        Text("")
                    }
                    ForEach($draft.points) { $cell in
                        GridRow {
                            TextField("x", text: $cell.x)
                                .textFieldStyle(.roundedBorder)
                                .font(ThubanFont.mono(12))
                                .frame(width: 120)
                            TextField("y", text: $cell.y)
                                .textFieldStyle(.roundedBorder)
                                .font(ThubanFont.mono(12))
                                .frame(width: 120)
                            IconButton(glyph: .close, label: "Remove point", size: 22, iconSize: 11) {
                                draft.points.removeAll { $0.id == cell.id }
                                if draft.points.isEmpty { draft.points = [SeriesDraft.Cell(x: "", y: "")] }
                            }
                        }
                    }
                }
                Button {
                    draft.points.append(SeriesDraft.Cell(x: "", y: ""))
                } label: {
                    HStack(spacing: 6) { Glyph(.plus, size: 12); Text("Add point") }
                }
                .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 6))
            }
        }
        .padding(12)
        .background(theme.panel2Color.opacity(0.5), in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
    }
}

// MARK: - Rail

/// The figures under review, with their status chips, plus the note about non-chart figures.
private struct FigureRail: View {
    @Environment(\.thubanTheme) private var theme
    var model: FigureReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Figures")
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.figures.enumerated()), id: \.element.id) { offset, figure in
                        FigureRailRow(
                            figure: figure,
                            number: offset + 1,
                            documentName: model.scope == .classWide ? model.document(for: figure)?.filename : nil,
                            isCurrent: figure.id == model.current?.id
                        ) { model.jump(to: figure.id) }
                    }
                }
            }
            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
            Text("Only charts are standardized. Diagrams, photos and tables keep their original image and are shown as-is next to their questions.")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .thubanPanel(padding: 14)
    }
}

private struct FigureRailRow: View {
    @Environment(\.thubanTheme) private var theme
    var figure: Figure
    var number: Int
    var documentName: String?
    var isCurrent: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(.figureClip, size: 14)
                    .foregroundStyle(isCurrent ? theme.brassInkColor : theme.inkDimColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Figure \(number) · p. \(figure.pageOrIndex)")
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(theme.inkColor)
                    if let documentName {
                        Text(documentName)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.inkFaintColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                FigureStatusChip(status: figure.status)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isCurrent ? theme.accentTintColor : (hovering ? theme.panel2Color : .clear),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Figure \(number), \(figure.status.rawValue)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
