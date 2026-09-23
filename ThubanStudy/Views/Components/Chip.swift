import SwiftUI
import ThubanCore

/// A soft status chip (pos / neg / warn / signal / neutral / accent), optionally with a leading dot or icon.
struct Chip: View {
    @Environment(\.thubanTheme) private var theme
    var text: String
    var kind: ChipKind = .neutral
    var dot: Bool = false
    var icon: IconName?

    init(_ text: String, kind: ChipKind = .neutral, dot: Bool = false, icon: IconName? = nil) {
        self.text = text
        self.kind = kind
        self.dot = dot
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 5.z) {
            if dot {
                Circle().fill(kind.colors(theme).text).frame(width: 6.z, height: 6.z)
            }
            if let icon { Icon(icon, size: 13) }
            Text(text)
        }
        .thubanChip(kind: kind)
    }
}

extension Chip {
    /// The chip for a question's mastery status.
    static func status(_ status: ProgressStatus) -> Chip {
        switch status {
        case .new: return Chip("New", kind: .neutral)
        case .learning: return Chip("Learning", kind: .warn)
        case .mastered: return Chip("Mastered", kind: .pos)
        case .needsReview: return Chip("Needs review", kind: .neg)
        }
    }

    /// The chip for a question's agent-classified type ("Initial value problems"); unclassified is muted.
    static func type(_ question: Question) -> Chip {
        question.type.isEmpty
            ? Chip(Question.unclassifiedLabel, kind: .neutral)
            : Chip(question.type, kind: .accent)
    }

    /// Marks a question the math engine regenerates with fresh numbers.
    static let regenerates = Chip("Regenerates", kind: .neutral, icon: .mathEngine)

    /// The chip for a question kind ("Math · engine", …).
    static func kind(_ kind: QuestionKind) -> Chip {
        switch kind {
        case .mathTemplate: return Chip("Math · engine", kind: .accent, icon: .mathEngine)
        case .numeric: return Chip("Numeric", kind: .neutral)
        case .shortAnswer: return Chip("Short answer", kind: .neutral)
        case .multipleChoice: return Chip("Multiple choice", kind: .neutral)
        case .freeResponse: return Chip("Free response", kind: .neutral)
        }
    }

    static func importStatus(_ document: ImportedDocument) -> Chip {
        switch document.status {
        case .queued: return Chip("Queued", kind: .neutral)
        case .reading: return Chip(document.statusDetail ?? "Reading", kind: .signal)
        case .extractingFigures: return Chip(document.statusDetail ?? "Extracting figures", kind: .signal)
        case .generating:
            let model = document.modelUsed.flatMap(ClaudeModel.init(modelId:))?.shortName
            return Chip(document.statusDetail ?? "Generating questions" + (model.map { " (\($0))" } ?? ""), kind: .signal)
        case .escalated: return Chip("Escalated to Opus", kind: .warn)
        case .done: return Chip("Done · \(document.questionCount) questions", kind: .pos)
        case .failed: return Chip(document.statusDetail ?? "Failed", kind: .neg)
        }
    }
}
