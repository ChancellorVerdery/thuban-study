import SwiftUI
import ThubanCore

/// Design board "Modal — answer check": per-part verdict rows with the engine's message and canonical forms,
/// the rules the engine applied, and Try again / Ask the tutor / Next question.
struct AnswerResultsSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var session: ClassSession
    var results: GradeResults

    var body: some View {
        ModalCard(title: title, width: 560) {
            VStack(alignment: .leading, spacing: 16.z) {
                summaryRow
                VStack(spacing: 8.z) {
                    ForEach(results.rows) { row in
                        VerdictRow(row: row)
                    }
                }
                rules
            }
        } actions: {
            Button("Try again") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            if let problem = results.firstProblemPart {
                Button("Ask the tutor about (\(problem.partId))") {
                    askTutor(about: problem)
                }
                .buttonStyle(.thubanSecondary)
            }
            Button("Next question") {
                dismiss()
                session.next()
            }
            .buttonStyle(.thubanPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(session.questionCount < 2)
        }
    }

    private var title: String {
        if results.gradedCount == 0 { return "Sent to the tutor" }
        if results.isFullyCorrect { return "All correct" }
        if results.correctCount == 0 { return "Not yet" }
        return "\(results.correctCount) of \(results.gradedCount) correct"
    }

    // MARK: Summary

    private var summaryRow: some View {
        HStack(spacing: 10.z) {
            Text(summaryText)
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let progress = results.progress {
                Chip.status(progress.status)
            }
            Text("seed \(results.seed.prefix(4))")
                .font(ThubanFont.mono(12))
                .foregroundStyle(theme.inkDimColor)
        }
    }

    private var summaryText: String {
        if results.gradedCount == 0 {
            return "This question has no automatically graded parts; the tutor reviews your work."
        }
        if results.isFullyCorrect {
            return "Every graded part is correct. Answer it again with fresh numbers to work toward mastery."
        }
        let wrong = results.gradedCount - results.correctCount
        return "\(wrong) part\(wrong == 1 ? "" : "s") to revisit. Your inputs stay in the form so you can fix them."
    }

    // MARK: Rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 6.z) {
            Text("Rules the engine applied")
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            ForEach(results.rules, id: \.self) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 8.z) {
                    Glyph(.dot, size: 10)
                        .foregroundStyle(theme.brassInkColor)
                    Text(rule)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Actions

    private func askTutor(about row: GradeResults.Row) {
        var message = "Can you help me with part (\(row.partId))?"
        let input = row.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty { message += " I entered $\(input)$" }
        if !row.verdict.message.isEmpty { message += " and the check said: \"\(row.verdict.message)\"" }
        message += "."
        session.studyState.composerText = message
        dismiss()
    }
}

/// One part: label, the student's input (mono), a verdict chip, the engine's message and canonical forms.
private struct VerdictRow: View {
    @Environment(\.thubanTheme) private var theme
    var row: GradeResults.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6.z) {
            HStack(alignment: .firstTextBaseline, spacing: 8.z) {
                Text("(\(row.partId))")
                    .font(ThubanFont.display(14))
                    .foregroundStyle(theme.inkColor)
                    .frame(width: 28.z, alignment: .leading)
                Text(row.input.isEmpty ? "— no answer —" : row.input)
                    .font(ThubanFont.mono(13))
                    .foregroundStyle(row.input.isEmpty ? theme.inkFaintColor : theme.inkColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                verdictChip
            }
            if !row.verdict.message.isEmpty {
                Text(row.verdict.message)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36.z)
            }
            if let canonical = canonicalLine {
                Text(canonical)
                    .font(ThubanFont.mono(12))
                    .foregroundStyle(theme.inkDimColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.leading, 36.z)
                    .textSelection(.enabled)
            }
        }
        .padding(12.z)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var verdictChip: some View {
        switch row.verdict.outcome {
        case .correct: return Chip("Correct", kind: .pos, dot: true)
        case .incorrect: return Chip("Incorrect", kind: .neg, dot: true)
        case .equivalentButConditionFailed: return Chip("Equivalent · condition failed", kind: .warn, dot: true)
        case .unparseable: return Chip("Couldn't read", kind: .neutral, dot: true)
        case .needsTutor: return Chip("Tutor reviews", kind: .signal, dot: true)
        }
    }

    /// Canonical forms as plain LaTeX. The expected form is shown only once the student has the equivalent value
    /// (correct, or equivalent but a condition failed) so a wrong attempt never reveals the answer.
    private var canonicalLine: String? {
        var pieces: [String] = []
        if let student = row.verdict.canonicalStudent, !student.isEmpty {
            pieces.append("yours: \(student)")
        }
        let revealsNothing = row.verdict.outcome == .correct || row.verdict.outcome == .equivalentButConditionFailed
        if revealsNothing, let expected = row.verdict.canonicalExpected, !expected.isEmpty, expected != row.verdict.canonicalStudent {
            pieces.append("expected form: \(expected)")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "   ·   ")
    }
}
