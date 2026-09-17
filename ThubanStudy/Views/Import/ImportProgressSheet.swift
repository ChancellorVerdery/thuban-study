import SwiftUI
import ThubanCore

/// "Import agent progress" modal: the per-file activity list (model chip + status line), the escalation notice
/// with Keep Opus / Use Sonnet anyway, the overall summary, and Run in background / Cancel import.
struct ImportProgressSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var session: ClassSession
    @State private var confirmingCancel = false

    private var pipeline: ImportPipeline { session.importPipeline }

    var body: some View {
        ModalCard(title: pipeline.isRunning ? "Importing into \(session.studyClass?.name ?? "this class")" : "Import finished", width: 560) {
            VStack(alignment: .leading, spacing: 16) {
                if let notice = pipeline.escalationNotice {
                    EscalationCard(notice: notice, onKeep: { pipeline.keepEscalation() }, onSonnet: { pipeline.pinSonnetForRun() })
                }
                activityList
                summary
            }
        } actions: {
            if pipeline.isRunning {
                Button("Cancel import") { confirmingCancel = true }
                    .buttonStyle(.thubanSecondary)
                Button("Run in background") { dismiss() }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Cancel the import?", isPresented: $confirmingCancel) {
            Button("Cancel import", role: .destructive) { pipeline.cancel() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Files already finished keep their questions. The current file goes back to the queue.")
        }
    }

    private var activityList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(pipeline.activities.enumerated()), id: \.element.id) { index, activity in
                    ActivityRow(activity: activity)
                    if index < pipeline.activities.count - 1 {
                        Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
        .thubanPanel(padding: 0)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressBar(value: pipeline.fractionFinished, height: 6)
            HStack {
                Text(pipeline.summaryLine)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
                Spacer()
                Text("Questions are added to the bank as each file finishes.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }
        }
    }
}

// MARK: - Rows

private struct ActivityRow: View {
    @Environment(\.thubanTheme) private var theme
    var activity: ImportPipeline.FileActivity

    var body: some View {
        HStack(spacing: 12) {
            phaseMark
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.filename)
                    .font(ThubanFont.body(14, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(activity.error ?? activity.detail)
                    .font(ThubanFont.small)
                    .foregroundStyle(activity.phase == .failed ? theme.negTextColor : theme.inkDimColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let model = activity.model {
                Chip(model.shortName, kind: model == .opus ? .warn : .neutral)
            }
            WarningsChip(warnings: activity.warnings, filename: activity.filename)
            if activity.phase == .done {
                Chip("\(activity.questionCount) question\(activity.questionCount == 1 ? "" : "s")", kind: .pos)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var phaseMark: some View {
        switch activity.phase {
        case .waiting:
            Circle().strokeBorder(theme.line2Color, lineWidth: 1.5).frame(width: 12, height: 12)
        case .done:
            Glyph(.check, size: 16).foregroundStyle(theme.posTextColor)
        case .failed:
            Glyph(.close, size: 16).foregroundStyle(theme.negTextColor)
        case .cancelled:
            Glyph(.close, size: 16).foregroundStyle(theme.inkFaintColor)
        case .reading, .figures, .generating, .escalated, .analysingFigures:
            ProgressView()
                .controlSize(.small)
                .tint(theme.accentColor)
        }
    }
}

// MARK: - Escalation notice

private struct EscalationCard: View {
    @Environment(\.thubanTheme) private var theme
    var notice: ImportPipeline.EscalationNotice
    var onKeep: () -> Void
    var onSonnet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Chip("Escalated to Opus", kind: .warn)
                Text(notice.filename)
                    .font(ThubanFont.body(14, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(notice.reason.isEmpty ? "The agent found this material dense enough to need Opus." : notice.reason)
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep Opus", action: onKeep)
                    .buttonStyle(PrimaryButtonStyle(height: 30))
                Button("Use Sonnet anyway", action: onSonnet)
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .help("Pins Sonnet for the remaining files of this run")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warnSoftColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.5), lineWidth: ThubanMetrics.hairline)
        )
    }
}
