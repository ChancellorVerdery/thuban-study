import SwiftUI
import ThubanCore

/// PLACEHOLDER — the screens phase replaces this file wholesale. A simple list of the class's questions.
struct QuestionBankView: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    var body: some View {
        Group {
            if session.questions.isEmpty {
                EmptyState(icon: .questionBank, title: "The question bank is empty",
                           message: "Import documents and the agent will build questions for this class.") {
                    Button("Import documents") { session.section = .importDocs }
                        .buttonStyle(.thubanPrimary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(session.questions.enumerated()), id: \.element.id) { index, question in
                            row(index: index, question: question)
                            if index < session.questions.count - 1 {
                                Rectangle().fill(theme.lineColor).frame(height: 1)
                            }
                        }
                    }
                    .thubanPanel(padding: 0)
                    .padding(16)
                }
            }
        }
        .task(id: session.classId) {
            if session.questions.isEmpty { await session.loadQuestions() }
        }
    }

    private func row(index: Int, question: Question) -> some View {
        Button {
            Task { await session.select(question: question) }
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(ThubanFont.mono(12))
                    .foregroundStyle(theme.inkFaintColor)
                    .frame(width: 28, alignment: .trailing)
                Text(question.stem)
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                Spacer()
                Chip.kind(question.kind)
                if let source = question.sourceRef {
                    Text(source)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
                Chip.status(session.status(of: question))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
