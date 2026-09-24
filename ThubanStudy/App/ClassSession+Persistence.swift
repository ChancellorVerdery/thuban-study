import AppKit
import Foundation
import ThubanCore

/// What a class remembers across launches: the screen it was on, the question being studied (with its numbers and
/// the answers typed so far), the Study filter and selection, the tools that were open, and the Question bank's
/// filters. Kept in the settings table under `classState.<class id>`.
struct SavedClassState: Codable, Equatable {
    var section: String = ClassSession.Section.study.rawValue
    var questionId: QuestionID?
    var seed: String?
    var inputs: [String: String] = [:]
    var filterTypes: [String] = []
    var filterStatuses: [ProgressStatus] = []
    var filterDocuments: [DocumentID] = []
    var queueScope: [QuestionID]?
    var showGraph = false
    var showCalculator = false
    var showKeyboard = false
    var graphMode: GraphMode = .twoD
    var bank = BankFilterState()

    static func key(for classId: ClassID) -> SettingsKey { SettingsKey("classState.\(classId.raw)") }
}

/// The Question bank's filters, carried by the session so they outlive the bank view.
struct BankFilterState: Codable, Equatable {
    var search = ""
    var types: [String] = []
    var statuses: [ProgressStatus] = []
    var documents: [DocumentID] = []
}

extension ClassSession {
    /// The state to save now.
    var savedState: SavedClassState {
        // Until the queue has been loaded (and the saved question restored), keep the saved question, answers and
        // filter as they were.
        if let pending = pendingRestore {
            var state = pending
            state.section = section.rawValue
            state.showGraph = showGraph
            state.showCalculator = showCalculator
            state.showKeyboard = showKeyboard
            state.graphMode = graphMode
            state.bank = bankFilter
            return state
        }
        return SavedClassState(
            section: section.rawValue,
            questionId: currentQuestion?.id,
            seed: currentInstance?.questionId == currentQuestion?.id ? currentInstance?.seed : nil,
            inputs: inputs,
            filterTypes: studyFilter.types.sorted(),
            filterStatuses: studyFilter.statuses.sorted { $0.rawValue < $1.rawValue },
            filterDocuments: studyFilter.documentIds.sorted(),
            queueScope: queueScope?.sorted(),
            showGraph: showGraph,
            showCalculator: showCalculator,
            showKeyboard: showKeyboard,
            graphMode: graphMode,
            bank: bankFilter
        )
    }

    /// Applies the parts of a saved state that need no questions (the rest is applied by `loadQuestions`).
    func applySaved(_ saved: SavedClassState) {
        section = Section(rawValue: saved.section) ?? .study
        showGraph = saved.showGraph
        showCalculator = saved.showCalculator
        showKeyboard = saved.showKeyboard
        graphMode = saved.graphMode
        bankFilter = saved.bank
    }

    /// Saves shortly after the last change (typing saves once it pauses).
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.saveNow()
        }
    }

    func saveNow() async {
        let state = savedState
        guard state != lastSaved else { return }
        do {
            try await store.set(SavedClassState.key(for: classId), state)
            lastSaved = state
        } catch {
            Self.logger.error("save class state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension AppModel {
    /// Reads every class's saved state (at launch, before any session is made).
    func loadSavedClassStates() async {
        var states: [ClassID: SavedClassState] = [:]
        for studyClass in classes {
            if let saved = try? await store.get(SavedClassState.key(for: studyClass.id), as: SavedClassState.self) {
                states[studyClass.id] = saved
            }
        }
        savedClassStates = states
    }

    /// Writes every open class's state (before the app quits).
    func saveAllClassStates() async {
        for session in sessions.values { await session.saveNow() }
        classStatesSaved = true
    }
}
