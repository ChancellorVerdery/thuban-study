import SwiftUI
import ThubanCore

/// The bank table: # | Question | Type | Source | Status | Last result. Double-click (or the "Study" context
/// action) opens the row in Study; the context menu also offers Edit…, Reset progress and Delete….
struct QuestionTable: View {
    @Environment(\.thubanTheme) private var theme
    var rows: [QuestionBankModel.Row]
    @Binding var selection: Set<QuestionID>
    var onStudy: (Question) -> Void
    var onEdit: (Question) -> Void
    var onReset: (Question) -> Void
    var onDelete: (Question) -> Void

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("#") { row in
                NumberCell(number: row.number, isCurrent: row.isCurrent)
            }
            .width(min: 44, ideal: 48, max: 56)

            TableColumn("Question") { row in
                StemCell(row: row)
            }
            .width(min: 240, ideal: 320)   // ideal widths must sum below the table width at 1280 pt or the trailing columns clip

            TableColumn("Type") { row in
                Chip.kind(row.question.kind)
            }
            .width(min: 110, ideal: 130, max: 150)

            TableColumn("Source") { row in
                Text(row.source)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.source)
            }
            .width(min: 120, ideal: 160, max: 260)

            TableColumn("Status") { row in
                Chip.status(row.status)
            }
            .width(min: 96, ideal: 112, max: 130)

            TableColumn("Last result") { row in
                Text(row.lastResult)
                    .font(ThubanFont.small)
                    .foregroundStyle(row.progress?.lastScore == nil ? theme.inkFaintColor : theme.inkDimColor)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 96, ideal: 120, max: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(theme.panelColor)
        .contextMenu(forSelectionType: QuestionID.self) { ids in
            if let question = single(ids) {
                Button("Study") { onStudy(question) }
                Button("Edit…") { onEdit(question) }
                Divider()
                Button("Reset progress") { onReset(question) }
                Button("Delete…", role: .destructive) { onDelete(question) }
            } else if !ids.isEmpty {
                Text("\(ids.count) questions selected")
            }
        } primaryAction: { ids in
            if let question = single(ids) { onStudy(question) }
        }
        .accessibilityLabel("Question bank table")
    }

    private func single(_ ids: Set<QuestionID>) -> Question? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return rows.first { $0.id == id }?.question
    }
}

/// Row number; the question currently open in Study gets a brass dot before it.
private struct NumberCell: View {
    @Environment(\.thubanTheme) private var theme
    var number: Int
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isCurrent ? theme.accentColor : .clear)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("\(number)")
                .font(ThubanFont.mono(12))
                .foregroundStyle(isCurrent ? theme.brassInkColor : theme.inkFaintColor)
                .monospacedDigit()
        }
        .accessibilityLabel(isCurrent ? "Question \(number), open in Study" : "Question \(number)")
    }
}

/// The stem as one truncated line (LaTeX shown as plain text). Tooltip shows the full stem.
private struct StemCell: View {
    @Environment(\.thubanTheme) private var theme
    var row: QuestionBankModel.Row

    var body: some View {
        HStack(spacing: 8) {
            Text(row.stemLine.isEmpty ? "Untitled question" : row.stemLine)
                .font(ThubanFont.body(14, weight: row.isCurrent ? .semibold : .regular))
                .foregroundStyle(theme.inkColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if row.question.parts.count > 1 {
                Text("\(row.question.parts.count) parts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.inkFaintColor)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if !row.question.figureIds.isEmpty {
                Icon(.figureClip, size: 13)
                    .foregroundStyle(theme.inkFaintColor)
                    .help("Has \(row.question.figureIds.count) figure\(row.question.figureIds.count == 1 ? "" : "s")")
            }
        }
        .help(row.stemLine)
        .padding(.vertical, 2)
    }
}
