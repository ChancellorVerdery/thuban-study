import SwiftUI
import ThubanCore

/// Question bank pane: import chunk size, automatic regeneration after a correct answer, mastery threshold.
struct QuestionBankSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    private var model: QuestionBankSettingsModel { app.questionBankSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 28.z) {
            SettingsGroup("Generating", caption: "How the import agent sizes a question bank from reading material.") {
                VStack(spacing: 0.z) {
                    SettingsRow("Questions per import chunk", detail: "A hint for readings: each chunk of about 12,000 tokens yields roughly this many questions. Documents that already contain questions are extracted as-is.") {
                        StepperControl(
                            value: Binding(get: { model.defaults.questionsPerChunk }, set: { model.setQuestionsPerChunk($0) }),
                            range: QuestionBankDefaults.chunkRange,
                            label: "Questions per import chunk"
                        )
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    SettingsRow("Files imported at once", detail: "How many files one import run works on in parallel. Each file has its own agent conversation; more at once finishes a big drop sooner but uses more of your account's rate limit.") {
                        StepperControl(
                            value: Binding(get: { model.defaults.parallelImports }, set: { model.setParallelImports($0) }),
                            range: QuestionBankDefaults.parallelRange,
                            label: "Files imported at once",
                            unit: model.defaults.parallelImports == 1 ? "file" : "files"
                        )
                    }
                }
                .thubanPanel(padding: 16)
                .padding(.top, 2.z)
            }

            SettingsGroup("Studying", caption: "What happens after you check an answer.") {
                VStack(spacing: 0.z) {
                    SettingsRow("Regenerate numbers automatically after a correct answer", detail: "Math-engine questions get fresh numbers as soon as every part is correct, so \"Next\" shows a new instance.") {
                        ThubanSwitch(
                            label: "Regenerate numbers automatically after a correct answer",
                            isOn: Binding(get: { model.defaults.autoRegenerateAfterCorrect }, set: { model.setAutoRegenerate($0) })
                        )
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    SettingsRow("Show figure descriptions", detail: "Each figure's written description above it, and as its spoken label for VoiceOver. Off by default: a description can give away what the figure shows.") {
                        ThubanSwitch(
                            label: "Show figure descriptions",
                            isOn: Binding(get: { app.showFigureDescriptions }, set: { app.setShowFigureDescriptions($0) })
                        )
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    SettingsRow("Mastery threshold", detail: "First-try correct answers in a row before a question counts as mastered. A wrong answer afterwards sends it back to Needs review.") {
                        StepperControl(
                            value: Binding(get: { model.defaults.masteryThreshold }, set: { model.setMasteryThreshold($0) }),
                            range: QuestionBankDefaults.masteryRange,
                            label: "Mastery threshold",
                            unit: model.defaults.masteryThreshold == 1 ? "correct" : "in a row"
                        )
                    }
                }
                .thubanPanel(padding: 16)
                .padding(.top, 2.z)
                HStack(spacing: 8.z) {
                    Chip.status(.new)
                    Glyph(.chevronRight, size: 12).foregroundStyle(theme.inkFaintColor)
                    Chip.status(.learning)
                    Glyph(.chevronRight, size: 12).foregroundStyle(theme.inkFaintColor)
                    Chip.status(.mastered)
                    Text("· wrong after mastered →")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                    Chip.status(.needsReview)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Progress order: new, learning, mastered; a wrong answer after mastered means needs review")
            }

            if let error = model.error {
                SettingsNote(error, tone: .negative)
            }
        }
        .task { await model.load() }
    }
}

/// A compact numeric stepper in Thuban's chrome: [−] value [+].
struct StepperControl: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var value: Int
    var range: ClosedRange<Int>
    var label: String
    var unit: String?

    var body: some View {
        HStack(spacing: 0.z) {
            stepButton(glyph: .chevronLeft, label: "Decrease \(label.lowercased())", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - 1)
            }
            HStack(spacing: 4.z) {
                Text("\(value)")
                    .font(ThubanFont.mono(14, weight: .medium))
                    .foregroundStyle(theme.inkColor)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                }
            }
            .frame(minWidth: 44.z)
            .padding(.horizontal, 6.z)
            stepButton(glyph: .chevronRight, label: "Increase \(label.lowercased())", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + 1)
            }
        }
        .frame(height: 32.z)
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private func stepButton(glyph: Glyph.Kind, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(glyph, size: 14)
                .foregroundStyle(enabled ? theme.inkDimColor : theme.inkFaintColor)
                .frame(width: 30.z, height: 32.z)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
