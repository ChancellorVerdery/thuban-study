import SwiftUI
import ThubanCore

/// Study mode's Filter dropdown: which questions the study queue holds, by type, status and source (the same
/// facets as the Question bank's filters), as checklists in a popover under a button in the Study header.
/// Changes apply at once; the counts are of the whole queue before filtering.
struct StudyFilterMenu: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession
    /// Development: `THUBAN_SMOKE_FILTER_OPEN` opens the dropdown at launch, for screenshots.
    @State private var isOpen = ProcessInfo.processInfo.environment["THUBAN_SMOKE_FILTER_OPEN"] != nil
    @State private var hovering = false

    private var filter: QuestionFilter { session.studyFilter }
    private var activeCount: Int { filter.types.count + filter.statuses.count + filter.documentIds.count }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6.z) {
                Text(activeCount == 0 ? "All questions" : "Filtered · \(activeCount)")
                    .font(.system(size: 12.z, weight: .semibold))
                Glyph(.chevronDown, size: 11)
            }
            .foregroundStyle(activeCount == 0 ? theme.inkDimColor : theme.brassInkColor)
            .padding(.horizontal, 10.z)
            .frame(height: 26.z)
            .background(
                activeCount > 0 ? theme.accentTintColor : (hovering ? theme.panel2Color : theme.panelColor),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
                    .strokeBorder(activeCount > 0 ? theme.accentColor : theme.line2Color, lineWidth: ThubanMetrics.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Choose which questions Study shows: by type, status and source")
        .accessibilityLabel(activeCount == 0 ? "Filter questions: all questions" : "Filter questions: \(activeCount) filters on")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            panel
        }
        .task(id: session.classId) {
            if session.importQueue.isEmpty { await session.loadDocuments() }
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Study questions")
                    .font(ThubanFont.body(14, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                Spacer()
                Text("\(session.questionCount) of \(session.unfilteredQuestions.count)")
                    .font(ThubanFont.mono(12))
                    .foregroundStyle(theme.inkDimColor)
                Button("Clear") { apply(QuestionFilter()) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.z, weight: .semibold))
                    .foregroundStyle(activeCount > 0 ? theme.brassInkColor : theme.inkFaintColor)
                    .disabled(activeCount == 0)
                    .padding(.leading, 8.z)
            }
            .padding(.horizontal, 14.z)
            .padding(.vertical, 12.z)
            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14.z) {
                    section("Type") {
                        ForEach(typeOptions, id: \.type) { option in
                            row(option.label, count: option.count, isOn: filter.types.contains(option.type)) {
                                var next = filter
                                if next.types.contains(option.type) { next.types.remove(option.type) } else { next.types.insert(option.type) }
                                apply(next)
                            }
                        }
                    }
                    section("Status") {
                        ForEach(ProgressStatus.allCases, id: \.self) { status in
                            row(Self.label(for: status), count: count(of: status), isOn: filter.statuses.contains(status)) {
                                var next = filter
                                if next.statuses.contains(status) { next.statuses.remove(status) } else { next.statuses.insert(status) }
                                apply(next)
                            }
                        }
                    }
                    if !sourceOptions.isEmpty {
                        section("Source") {
                            ForEach(sourceOptions, id: \.id) { option in
                                row(option.label, count: option.count, isOn: filter.documentIds.contains(option.id)) {
                                    var next = filter
                                    if next.documentIds.contains(option.id) { next.documentIds.remove(option.id) } else { next.documentIds.insert(option.id) }
                                    apply(next)
                                }
                            }
                        }
                    }
                }
                .padding(14.z)
            }
            .frame(maxHeight: 460.z)
        }
        .frame(width: 340.z)
        .background(theme.panelColor)
    }

    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 2.z) {
            Text(title)
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
                .padding(.bottom, 4.z)
            rows()
        }
    }

    private func row(_ label: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        StudyFilterRow(label: label, count: count, isOn: isOn, action: action)
    }

    private func apply(_ next: QuestionFilter) {
        Task { await session.setStudyFilter(next) }
    }

    // MARK: Options (counted over the unfiltered queue)

    private var typeOptions: [(type: String, label: String, count: Int)] {
        let counts = Dictionary(grouping: session.unfilteredQuestions, by: \.type).mapValues(\.count)
        return counts.map { (type: $0.key, label: $0.key.isEmpty ? Question.unclassifiedLabel : $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func count(of status: ProgressStatus) -> Int {
        session.unfilteredQuestions.filter { session.status(of: $0) == status }.count
    }

    private var sourceOptions: [(id: DocumentID, label: String, count: Int)] {
        let counts = Dictionary(grouping: session.unfilteredQuestions.compactMap(\.documentId), by: { $0 }).mapValues(\.count)
        return session.importQueue.compactMap { document in
            counts[document.id].map { (id: document.id, label: Self.shortName(document.filename), count: $0) }
        }
    }

    /// "2.1 Homework - Solution Curves … _ WebAssign.mhtml" → "2.1 Homework - Solution Curves …" (no extension).
    static func shortName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
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

/// One checklist row: a checkbox, the label and its count.
private struct StudyFilterRow: View {
    @Environment(\.thubanTheme) private var theme
    var label: String
    var count: Int
    var isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8.z) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.z, style: .continuous)
                        .fill(isOn ? theme.accentColor : theme.panelColor)
                    RoundedRectangle(cornerRadius: 4.z, style: .continuous)
                        .strokeBorder(isOn ? theme.accentColor : theme.line2Color, lineWidth: ThubanMetrics.hairline)
                    if isOn { Glyph(.check, size: 11).foregroundStyle(theme.panelColor) }
                }
                .frame(width: 16.z, height: 16.z)
                Text(label)
                    .font(ThubanFont.body(13))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8.z)
                Text("\(count)")
                    .font(ThubanFont.mono(11))
                    .foregroundStyle(theme.inkDimColor)
            }
            .padding(.horizontal, 6.z)
            .frame(height: 28.z)
            .background(hovering ? theme.panel2Color : Color.clear, in: RoundedRectangle(cornerRadius: 6.z, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "selected, \(count) questions" : "\(count) questions")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
