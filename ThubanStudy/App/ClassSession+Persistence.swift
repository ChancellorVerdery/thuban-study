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
    /// Optional so states saved before the equations panel existed still decode.
    var showEquations: Bool?
    var graphMode: GraphMode = .twoD
    /// Optional so states saved before shuffle existed still decode.
    var shuffle: Bool?
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
            state.showEquations = showEquations
            state.graphMode = graphMode
            state.shuffle = shuffle
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
            showEquations: showEquations,
            graphMode: graphMode,
            shuffle: shuffle,
            bank: bankFilter
        )
    }

    /// Applies the parts of a saved state that need no questions (the rest is applied by `loadQuestions`).
    func applySaved(_ saved: SavedClassState) {
        section = Section(rawValue: saved.section) ?? .study
        showGraph = saved.showGraph
        showCalculator = saved.showCalculator
        showKeyboard = saved.showKeyboard
        showEquations = saved.showEquations ?? false
        graphMode = saved.graphMode
        shuffle = saved.shuffle ?? false
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
    /// Writes every class's unsaved state, blocking (up to 2 s) until the store has it. The snapshots are taken here
    /// on the main thread; the writes run off it, so waiting cannot deadlock.
    func saveAllClassStatesBeforeExit() {
        let pending = sessions.values.compactMap { session -> (SettingsKey, SavedClassState)? in
            let state = session.savedState
            return state == session.lastSaved ? nil : (SavedClassState.key(for: session.classId), state)
        }
        guard !pending.isEmpty else { return }
        let store = store
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for (key, state) in pending { try? await store.set(key, state) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
