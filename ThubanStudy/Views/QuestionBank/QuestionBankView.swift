import SwiftUI
import ThubanCore

/// The Question bank: header (title, counts, Study all / Import more, search), filter chip rows, a Sources rail
/// with the Figures entry, the question table with context actions, and a paged footer.
struct QuestionBankView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession
    @State private var model: QuestionBankModel
    @State private var editing: Question?
    @State private var batchEditing: QuestionBatch?
    @State private var pendingDelete: Question?
    @State private var pendingBatchDelete: [Question]?
    @FocusState private var searchFocused: Bool

    init(session: ClassSession) {
        self.session = session
        _model = State(initialValue: QuestionBankModel(session: session))
    }

    var body: some View {
        Group {
            switch model.screen {
            case .table:
                bank
            case .figures:
                FigureReviewView(session: session, scope: .classWide, breadcrumbRoot: "Question bank") {
                    model.screen = .table
                    Task { await model.load() }
                }
            }
        }
        .task(id: session.classId) { await model.load() }
        // The categorizer finished a class: show the new types.
        .onChange(of: app.categoriesChanged) { _, _ in
            Task { await model.refreshAfterChange() }
        }
        .onChange(of: session.pendingBankSelection, initial: true) { _, pending in
            guard let pending else { return }
            model.selection = pending
            session.pendingBankSelection = nil
        }
        .sheet(item: $editing) { question in
            QuestionEditSheet(question: question, knownTypes: model.typeChips.map(\.type).filter { !$0.isEmpty }) { edited in
                Task {
                    do {
                        try await session.save(question: edited)
                        await model.refreshAfterChange()
                    } catch {
                        model.error = error.localizedDescription
                    }
                }
            }
            .environment(\.thubanTheme, theme)
        }
        .sheet(item: $batchEditing) { batch in
            BatchEditSheet(questions: batch.questions, knownTypes: model.typeChips.map(\.type).filter { !$0.isEmpty }) { edited in
                Task {
                    do {
                        try await session.save(questions: edited)
                        await model.refreshAfterChange()
                    } catch {
                        model.error = error.localizedDescription
                    }
                }
            }
            .environment(\.thubanTheme, theme)
        }
        .confirmationDialog(
            "Delete \(pendingBatchDelete?.count ?? 0) questions?",
            isPresented: Binding(get: { pendingBatchDelete != nil }, set: { if !$0 { pendingBatchDelete = nil } }),
            presenting: pendingBatchDelete
        ) { questions in
            Button("Delete \(questions.count) questions", role: .destructive) {
                Task {
                    do {
                        try await session.delete(questions: questions)
                        model.selection = []
                        await model.refreshAfterChange()
                    } catch {
                        model.error = error.localizedDescription
                    }
                }
            }
            Button("Keep", role: .cancel) {}
        } message: { questions in
            Text("The \(questions.count) selected questions and their attempts will be removed. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete this question?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { question in
            Button("Delete question", role: .destructive) {
                Task {
                    do {
                        try await session.delete(question: question)
                        await model.refreshAfterChange()
                    } catch {
                        model.error = error.localizedDescription
                    }
                }
            }
            Button("Keep", role: .cancel) {}
        } message: { question in
            Text("“\(QuestionBankModel.plainLine(question.stem).prefix(80))” and its attempts will be removed. This cannot be undone.")
        }
    }

    // MARK: Bank layout

    private var bank: some View {
        VStack(spacing: 0.z) {
            BankHeader(model: model, session: session, searchFocused: $searchFocused)
                .padding(.horizontal, 24.z)
                .padding(.top, 22.z)
                .padding(.bottom, 14.z)
            BankFilterRows(model: model)
                .padding(.horizontal, 24.z)
                .padding(.bottom, 14.z)
            HStack(alignment: .top, spacing: 16.z) {
                BankSourceRail(model: model)
                    .frame(width: 220.z)
                VStack(spacing: 0.z) {
                    if model.allQuestions.isEmpty, !model.isLoading {
                        emptyBank
                    } else if model.filtered.isEmpty {
                        noMatches
                    } else {
                        QuestionTable(
                            rows: model.pageRows,
                            selection: $model.selection,
                            resolve: model.questions(for:),
                            onStudy: study(_:),
                            onEdit: edit(_:),
                            onReset: reset(_:),
                            onDelete: confirmDelete(_:)
                        )
                    }
                    BankFooter(model: model, onStudy: study(_:), onEdit: edit(_:), onReset: reset(_:), onDelete: confirmDelete(_:))
                }
                .thubanPanel(padding: 0)
            }
            .padding(.horizontal, 24.z)
            .padding(.bottom, 20.z)
            if let error = model.error {
                Text(error)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.negTextColor)
                    .padding(.horizontal, 24.z)
                    .padding(.bottom, 12.z)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var emptyBank: some View {
        EmptyState(icon: .questionBank, title: "The question bank is empty",
                   message: "Import documents and the agent will build questions for this class.") {
            Button("Import documents") { session.section = .importDocs }
                .buttonStyle(.thubanPrimary)
        }
    }

    private var noMatches: some View {
        EmptyState(icon: .questionBank, title: "No questions match",
                   message: "Try another search or clear the filters.") {
            Button("Clear filters") { model.clearFilters() }
                .buttonStyle(.thubanSecondary)
        }
    }

    // MARK: Actions (one question or the whole selection)

    private func study(_ questions: [Question]) {
        Task { await session.study(selection: questions) }
    }

    private func edit(_ questions: [Question]) {
        if questions.count == 1 {
            editing = questions[0]
        } else if questions.count > 1 {
            batchEditing = QuestionBatch(questions: questions)
        }
    }

    private func reset(_ questions: [Question]) {
        Task {
            do {
                try await session.resetProgress(of: questions)
                await model.refreshAfterChange()
            } catch {
                model.error = error.localizedDescription
            }
        }
    }

    private func confirmDelete(_ questions: [Question]) {
        if questions.count == 1 {
            pendingDelete = questions[0]
        } else if questions.count > 1 {
            pendingBatchDelete = questions
        }
    }
}

/// A selection handed to the batch editor as a sheet item.
private struct QuestionBatch: Identifiable {
    var questions: [Question]
    var id: String { questions.map(\.id.raw).joined(separator: ",") }
}

// MARK: - Header

private struct BankHeader: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var model: QuestionBankModel
    var session: ClassSession
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .center, spacing: 16.z) {
            VStack(alignment: .leading, spacing: 4.z) {
                Text("Question bank")
                    .font(ThubanFont.display(28))
                    .foregroundStyle(theme.inkColor)
                Text(model.subtitle)
                    .font(ThubanFont.body(15))
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
                if session.app.isCategorizing, session.app.categorizingClass == session.classId {
                    HStack(spacing: 6.z) {
                        ProgressView().controlSize(.small)
                        Text("Sorting questions into types…")
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.inkDimColor)
                    }
                }
            }
            Spacer(minLength: 12)
            BankSearchField(text: $model.searchText, focused: searchFocused)
                .frame(width: 260.z)
            Button("Import more") { session.section = .importDocs }
                .buttonStyle(.thubanSecondary)
            Button("Study all") { Task { await session.studyAll() } }
                .buttonStyle(.thubanPrimary)
                .disabled(model.allQuestions.isEmpty)
                .help("Study every question, starting from the top of the queue")
        }
    }
}

/// Search field in the app's control chrome: search glyph, placeholder, clear button.
private struct BankSearchField: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8.z) {
            Glyph(.search, size: 15)
                .foregroundStyle(theme.inkFaintColor)
            TextField("Search questions  ⌘F", text: $text)
                .textFieldStyle(.plain)
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkColor)
                .focused(focused)
                .onExitCommand { text = ""; focused.wrappedValue = false }
            if !text.isEmpty {
                IconButton(glyph: .close, label: "Clear search", size: 22, iconSize: 12) { text = "" }
            }
        }
        .padding(.horizontal, 10.z)
        .frame(height: ThubanMetrics.buttonHeight)
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                .strokeBorder(focused.wrappedValue ? theme.accentColor : theme.line2Color, lineWidth: ThubanMetrics.hairline)
        )
        .accessibilityLabel("Search questions")
    }
}

// MARK: - Filter rows

private struct BankFilterRows: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var model: QuestionBankModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8.z) {
            filterRow("Type") {
                FilterChip(label: "All", count: model.allQuestions.count, isOn: model.types.isEmpty) { model.types = [] }
                ForEach(model.typeChips, id: \.type) { chip in
                    FilterChip(label: chip.label, count: chip.count, isOn: model.types.contains(chip.type)) {
                        model.toggle(type: chip.type)
                    }
                }
            }
            filterRow("Status") {
                ForEach(ProgressStatus.allCases, id: \.self) { status in
                    FilterChip(label: Self.label(for: status), count: model.count(of: status), isOn: model.statuses.contains(status)) {
                        model.toggle(status: status)
                    }
                }
            }
            if !model.sources.isEmpty {
                filterRow("Source") {
                    ForEach(model.sources, id: \.document.id) { source in
                        FilterChip(label: source.document.filename, count: source.count, isOn: model.documentIds.contains(source.document.id)) {
                            model.toggle(document: source.document.id)
                        }
                    }
                }
            }
        }
    }

    private func filterRow<Chips: View>(_ label: String, @ViewBuilder chips: () -> Chips) -> some View {
        HStack(alignment: .center, spacing: 8.z) {
            Text(label)
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
                .frame(width: 56.z, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6.z) { chips() }
            }
            .scrollClipDisabled()
        }
    }

    static func label(for status: ProgressStatus) -> String {
        switch status {
        case .new: return "New"
        case .learning: return "Learning"
        case .mastered: return "Mastered"
        case .needsReview: return "Needs review"
        }
    }
}

/// A toggleable filter chip with a count. Selected: accent tint + brass text + accent border.
private struct FilterChip: View {
    @Environment(\.thubanTheme) private var theme
    var label: String
    var count: Int
    var isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6.z) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220.z)
                Text("\(count)")
                    .font(ThubanFont.mono(11))
                    .foregroundStyle(isOn ? theme.brassInkColor : theme.inkDimColor)
            }
            .font(.system(size: 12.z, weight: .semibold))
            .foregroundStyle(isOn ? theme.brassInkColor : theme.inkDimColor)
            .padding(.horizontal, 9.z)
            .frame(height: 26.z)
            .background(
                isOn ? theme.accentTintColor : (hovering ? theme.panel2Color : theme.panelColor),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
                    .strokeBorder(isOn ? theme.accentColor : theme.lineColor, lineWidth: ThubanMetrics.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Source rail

private struct BankSourceRail: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var model: QuestionBankModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4.z) {
            Text("Sources")
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
                .padding(.horizontal, 10.z)
                .padding(.top, 12.z)
                .padding(.bottom, 6.z)
            RailRow(icon: .questionBank, label: "All sources", count: model.allQuestions.count, isActive: model.documentIds.isEmpty) {
                model.showSource(nil)
            }
            ForEach(model.sources, id: \.document.id) { source in
                RailRow(icon: .classTab, label: source.document.filename, count: source.count,
                        isActive: model.documentIds == [source.document.id]) {
                    model.showSource(source.document.id)
                }
            }
            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                .padding(.vertical, 6.z)
                .padding(.horizontal, 10.z)
            RailRow(icon: .figureClip, label: "Figures", count: model.figureCount, isActive: false) {
                model.screen = .figures
            }
            .disabled(model.figureCount == 0)
            .help(model.figureCount == 0 ? "No figures were clipped from this class's documents" : "Review the figures clipped from this class's documents")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6.z)
        .padding(.bottom, 8.z)
        .frame(maxHeight: .infinity, alignment: .top)
        .thubanPanel(padding: 0)
    }
}

private struct RailRow: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var icon: IconName
    var label: String
    var count: Int
    var isActive: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8.z) {
                Icon(icon, size: 15)
                    .foregroundStyle(isActive ? theme.brassInkColor : theme.inkDimColor)
                Text(label)
                    .font(.system(size: 13.z, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(ThubanFont.mono(11))
                    .foregroundStyle(theme.inkDimColor)
            }
            .padding(.horizontal, 10.z)
            .frame(height: 30.z)
            .background(
                isActive ? theme.accentTintColor : (hovering ? theme.panel2Color : .clear),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - Footer

private struct BankFooter: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var model: QuestionBankModel
    var onStudy: ([Question]) -> Void
    var onEdit: ([Question]) -> Void
    var onReset: ([Question]) -> Void
    var onDelete: ([Question]) -> Void

    private var selected: [Question] { model.questions(for: model.selection) }

    var body: some View {
        HStack(spacing: 8.z) {
            Text(model.pageLabel)
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
                .monospacedDigit()
            if model.hasActiveFilter {
                Button("Clear filters") { model.clearFilters() }
                    .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 6))
            }
            if !selected.isEmpty {
                selectionBar
            }
            Spacer()
            if model.pageCount > 1 {
                Text("Page \(model.page + 1) of \(model.pageCount)")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
            }
            IconButton(glyph: .chevronLeft, label: "Previous page", size: 26, iconSize: 14) { model.previousPage() }
                .disabled(!model.canGoBack)
                .opacity(model.canGoBack ? 1 : 0.4)
            IconButton(glyph: .chevronRight, label: "Next page", size: 26, iconSize: 14) { model.nextPage() }
                .disabled(!model.canGoForward)
                .opacity(model.canGoForward ? 1 : 0.4)
        }
        .padding(.horizontal, 12.z)
        .frame(height: 40.z)
        .thubanHairline(.top, color: theme.lineColor)
    }

    /// "N selected · Study · Edit… · Reset · Delete…" — the row actions, for the whole selection.
    private var selectionBar: some View {
        HStack(spacing: 4.z) {
            Rectangle().fill(theme.lineColor).frame(width: ThubanMetrics.hairline, height: 18.z)
            Text("\(selected.count) selected")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkColor)
                .monospacedDigit()
                .padding(.horizontal, 4.z)
            Button("Study") { onStudy(selected) }
                .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 6))
                .help(selected.count == 1 ? "Open in Study" : "Study just these questions")
            Button("Edit…") { onEdit(selected) }
                .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 6))
                .help(selected.count == 1 ? "Edit this question" : "Set the type or difficulty of all selected")
            Button("Reset") { onReset(selected) }
                .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 6))
                .help("Forget attempts and progress")
            Button("Delete…") { onDelete(selected) }
                .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 6))
                .foregroundStyle(theme.negTextColor)
            Button("Clear") { model.selection = [] }
                .buttonStyle(GhostButtonStyle(height: 26, tinted: false, horizontalPadding: 6))
        }
    }
}
