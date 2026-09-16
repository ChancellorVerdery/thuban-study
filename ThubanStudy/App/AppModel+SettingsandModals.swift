import Foundation
import Observation
import ThubanCore

/// `ThubanCore.ColorScheme` without the clash with `SwiftUI.ColorScheme` in view files.
typealias ThubanScheme = ThubanCore.ColorScheme

// MARK: - Settings keys owned by the Settings screen

extension SettingsKey {
    /// Int: how many questions the import agent is asked for per reading chunk.
    static let questionsPerChunk: SettingsKey = "questionBank.questionsPerChunk"
    /// Bool: draw fresh numbers for a math template right after a correct answer.
    static let autoRegenerateAfterCorrect: SettingsKey = "questionBank.autoRegenerateAfterCorrect"
    /// Int: consecutive first-try correct answers that mark a question mastered.
    static let masteryThreshold: SettingsKey = "questionBank.masteryThreshold"
}

/// The "Question bank" defaults (persisted per key under `SettingsKey`).
struct QuestionBankDefaults: Codable, Equatable, Sendable {
    var questionsPerChunk: Int = 8
    var autoRegenerateAfterCorrect: Bool = true
    var masteryThreshold: Int = 2

    static let chunkRange = 4...16
    static let masteryRange = 1...5

    /// Values clamped to their allowed ranges.
    var clamped: QuestionBankDefaults {
        var copy = self
        copy.questionsPerChunk = min(max(questionsPerChunk, Self.chunkRange.lowerBound), Self.chunkRange.upperBound)
        copy.masteryThreshold = min(max(masteryThreshold, Self.masteryRange.lowerBound), Self.masteryRange.upperBound)
        return copy
    }
}

/// Loads and persists `QuestionBankDefaults` through the store. One per `AppModel` (see `AppModel.questionBankSettings`).
@MainActor
@Observable
final class QuestionBankSettingsModel {
    private(set) var defaults = QuestionBankDefaults()
    private(set) var isLoaded = false
    private(set) var error: String?
    @ObservationIgnored private let store: Store

    init(store: Store) {
        self.store = store
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            var loaded = QuestionBankDefaults()
            if let chunk = try await store.get(.questionsPerChunk, as: Int.self) { loaded.questionsPerChunk = chunk }
            if let auto = try await store.get(.autoRegenerateAfterCorrect, as: Bool.self) { loaded.autoRegenerateAfterCorrect = auto }
            if let mastery = try await store.get(.masteryThreshold, as: Int.self) { loaded.masteryThreshold = mastery }
            defaults = loaded.clamped
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }

    func setQuestionsPerChunk(_ value: Int) {
        defaults.questionsPerChunk = value
        defaults = defaults.clamped
        persist(.questionsPerChunk, defaults.questionsPerChunk)
    }

    func setAutoRegenerate(_ value: Bool) {
        defaults.autoRegenerateAfterCorrect = value
        persist(.autoRegenerateAfterCorrect, value)
    }

    func setMasteryThreshold(_ value: Int) {
        defaults.masteryThreshold = value
        defaults = defaults.clamped
        persist(.masteryThreshold, defaults.masteryThreshold)
    }

    /// Back to the built-in defaults (after "Delete all data").
    func reset() {
        defaults = QuestionBankDefaults()
        isLoaded = true
    }

    private func persist<T: Codable>(_ key: SettingsKey, _ value: T) {
        Task {
            do {
                try await store.set(key, value)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - AppModel additions for Settings

extension AppModel {
    /// Helper models keyed by the owning `AppModel` (extensions cannot add stored properties).
    private static var questionBankModels: [ObjectIdentifier: QuestionBankSettingsModel] = [:]

    /// The question-bank defaults model for this app (created lazily).
    var questionBankSettings: QuestionBankSettingsModel {
        let key = ObjectIdentifier(self)
        if let existing = Self.questionBankModels[key] { return existing }
        let model = QuestionBankSettingsModel(store: store)
        Self.questionBankModels[key] = model
        return model
    }

    /// The text shown for the connected account ("you@example.com" or "your Claude account").
    var connectedAccountLabel: String {
        switch connection {
        case .oauth(let email, _):
            return email?.nilIfEmpty ?? "your Claude account"
        case .apiKey:
            return "an API key"
        case .notConnected:
            return "not connected"
        }
    }

    /// Removes every class (with its files), every stored setting, and leftover files under the data directory.
    /// Credentials in the Keychain are left alone; call `disconnect()` separately for those.
    func deleteAllData() async throws {
        for studyClass in classes {
            try await deleteClass(studyClass.id, deleteFiles: true)
        }
        for key in try await store.settingsKeys() {
            try await store.remove(key)
        }
        Self.removeContents(of: [AppPaths.documents, AppPaths.figures, AppPaths.exports])

        // Restore in-memory settings to their defaults (each call persists its default again).
        setThemeSelection(.default)
        setModelPolicy(.default)
        setTutorMayEditGraph(true)
        setDesmosKey(Self.bundledDesmosKey ?? "")
        Self.questionBankModels[ObjectIdentifier(self)]?.reset()
    }

    private static func removeContents(of directories: [URL]) {
        let fm = FileManager.default
        for directory in directories {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
    }
}

// MARK: - Terms for the New class sheet

/// Academic terms around today's date: the current term followed by the next two.
enum AcademicTerms {
    static func suggestions(around date: Date = Date(), calendar: Calendar = .current) -> [String] {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        let order = ["Spring", "Summer", "Fall"]
        let startIndex: Int
        switch month {
        case 1...5: startIndex = 0
        case 6...7: startIndex = 1
        default: startIndex = 2
        }
        var result: [String] = []
        var index = startIndex
        var currentYear = year
        for _ in 0..<3 {
            result.append("\(order[index]) \(currentYear)")
            index += 1
            if index == order.count {
                index = 0
                currentYear += 1
            }
        }
        return result
    }
}

// MARK: - Class content counts (Delete class confirmation)

/// What a class holds, for the "Delete class" confirmation body.
struct ClassContentCounts: Equatable, Sendable {
    var questions = 0
    var documents = 0
    var figures = 0
    /// Bytes of the imported files on disk (0 when nothing is stored).
    var documentBytes = 0

    var isEmpty: Bool { questions == 0 && documents == 0 && figures == 0 }
}

extension AppModel {
    /// Counts the questions, documents and figures of a class (for `DeleteClassAlert`).
    func contentCounts(for classId: ClassID) async throws -> ClassContentCounts {
        var counts = ClassContentCounts()
        counts.questions = try await store.questionCount(in: classId)
        let documents = try await store.documents(in: classId)
        counts.documents = documents.count
        counts.documentBytes = documents.reduce(0) { $0 + $1.byteCount }
        for document in documents {
            counts.figures += try await store.figures(for: document.id).count
        }
        return counts
    }
}

// MARK: - Tab tints (New class sheet)

/// One choice in the "Tab color" row: a `nil` hex means "use the scheme accent".
struct ClassTintOption: Identifiable, Hashable {
    var id: String
    var label: String
    var hex: String?

    /// The id of the "use the scheme accent" option.
    static let accentId = "accent"

    /// Legible ink (dark or light) for a glyph drawn over a dot of this color.
    static func inkOn(_ hex: String) -> String {
        (try? ColorMath.onAccent(hex)) ?? ColorMath.darkOnAccent
    }

    /// The six options for a theme: the scheme accent, then five colors taken from or derived from the scheme.
    static func options(for theme: ResolvedTheme) -> [ClassTintOption] {
        var result: [ClassTintOption] = [
            ClassTintOption(id: accentId, label: "Scheme accent", hex: nil),
            ClassTintOption(id: "signal", label: "Highlight", hex: theme.signal),
            ClassTintOption(id: "pos", label: "Gain", hex: theme.pos),
            ClassTintOption(id: "neg", label: "Loss", hex: theme.neg),
        ]
        if let cool = try? SchemeDeriver.rotate(theme.accent, by: 200) {
            result.append(ClassTintOption(id: "cool", label: "Cool", hex: cool))
        }
        if let deep = try? SchemeDeriver.rotate(theme.accent, by: 280) {
            result.append(ClassTintOption(id: "deep", label: "Deep", hex: deep))
        }
        return result
    }
}
