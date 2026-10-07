import AppKit
import Foundation
import Observation
import StudyGraph
import ThubanCore
import os

/// Root model: owns the store, engine, credentials, theme, classes and one `ClassSession` per class.
/// AI/agent calls live in extensions the screens add (`AppModel+Study.swift`, …), not here.
@MainActor
@Observable
final class AppModel {
    static let logger = Logger(subsystem: "com.thuban.study", category: "app")

    // MARK: Services

    let store: Store
    /// Grading, templates and figures (ThubanCore's Compute Engine).
    let engine: MathEngine
    /// Every graph and calculator (the Thuban Graph engine, loaded when a graph or calculator first opens).
    let graphEngine = StudyGraphEngine()
    let credentials: CredentialStore
    /// Shared Messages API client; auth is looked up per call through `credentials`.
    let claudeClient: ClaudeClient
    let commands = CommandBus()

    /// Set when the on-disk store could not be opened (the app then runs on an in-memory store).
    private(set) var startupError: String?

    // MARK: Connection

    private(set) var connection: ConnectionStatus = .notConnected
    var isConnected: Bool { connection.isConnected }
    /// What the connection chips say: "Connected", "Sign in again" (credentials need attention) or "Not connected".
    var connectionSummary: String {
        if connection.isConnected { return "Connected" }
        return connection.needsAttention ? "Sign in again" : "Not connected"
    }
    /// The last failure from Disconnect (a Keychain delete the OS refused); shown on the account card.
    private(set) var accountError: String?

    // MARK: Theme

    private(set) var themeSelection: ThemeSelection = .default
    private(set) var systemIsDark: Bool = false
    private(set) var theme: ResolvedTheme = ThemeResolver.resolve(.default, systemIsDark: false)
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    // MARK: Classes and sessions

    private(set) var classes: [StudyClass] = []
    var selectedClassID: ClassID? {
        didSet {
            guard oldValue != selectedClassID else { return }
            let id = selectedClassID
            Task { try? await store.set(.lastClass, id) }
        }
    }
    private(set) var sessions: [ClassID: ClassSession] = [:]
    /// The categorizer's background pass (`categorizeUnclassifiedQuestions`): running, the class it is on, and a
    /// counter bumped after each class so the bank reloads.
    var isCategorizing = false
    var categorizingClass: ClassID?
    var categoriesChanged = 0
    @ObservationIgnored var isPinningConstants = false
    @ObservationIgnored var isConvertingDiagrams = false
    /// Each class's state from the last run, read at launch and applied when its session is made.
    @ObservationIgnored var savedClassStates: [ClassID: SavedClassState] = [:]
    private(set) var isLoaded = false

    var selectedClass: StudyClass? {
        guard let selectedClassID else { return nil }
        return classes.first { $0.id == selectedClassID }
    }

    /// The session of the selected class (created lazily).
    var selectedSession: ClassSession? {
        guard let selectedClassID, classes.contains(where: { $0.id == selectedClassID }) else { return nil }
        return session(for: selectedClassID)
    }

    /// The selected session only while its Study section is on screen (the target of the Study menu commands).
    var studySession: ClassSession? {
        guard let session = selectedSession, session.section == .study else { return nil }
        return session
    }

    // MARK: Settings values

    private(set) var modelPolicy: ModelPolicy = .default
    private(set) var tutorMayEditGraph = true
    private(set) var showFigureDescriptions = false
    /// Settings › Graph: draw the graph paper in the opposite light/dark mode.
    private(set) var graphReverseContrast = false

    // MARK: Shell UI state

    var isPresentingNewClass = false
    /// Class awaiting delete confirmation (drives `DeleteClassAlert`).
    var classPendingDelete: StudyClass?
    /// Bumped by ⌘I / the Import command; `ImportView` opens its file panel when it changes.
    private(set) var importPanelRequest = 0
    /// Bumped by ⌘, when no window handler is registered; `ShellView` opens the Settings window.
    private(set) var settingsRequest = 0

    // MARK: Init

    init() {
        var openedStore: Store
        var error: String?
        do {
            // A `--refresh-icon` launch draws the icon and exits; it must never open (or migrate) the database.
            openedStore = SharedTheme.isRefreshLaunch ? try Store.inMemory() : try Store.open()
        } catch let storeError {
            error = storeError.localizedDescription
            Self.logger.error("Store failed to open: \(storeError.localizedDescription, privacy: .public)")
            openedStore = (try? Store.inMemory()) ?? Self.unrecoverableStore()
        }
        store = openedStore
        startupError = error
        engine = MathEngine()
        let credentials = CredentialStore()
        self.credentials = credentials
        claudeClient = ClaudeClient(authProvider: { try await credentials.currentAuth() })

        if let shared = SharedTheme.load() { themeSelection = shared }
        systemIsDark = Self.currentSystemIsDark()
        theme = ThemeResolver.resolve(themeSelection, systemIsDark: systemIsDark)
        // `NSApp` does not exist yet while the App's @State is constructed; appearance observation starts in `load()`.
    }

    private static func unrecoverableStore() -> Store {
        // Both the on-disk and the in-memory store failed to open; nothing sensible can run.
        fatalError("Thuban Study could not open a database.")
    }

    // MARK: Launch

    /// Loads settings and classes and restores the last selected class. Safe to call once at launch.
    func load() async {
        if appearanceObservation == nil { observeAppearance() }
        observeSharedTheme()
        do {
            try AppPaths.ensureDirectories()
        } catch {
            startupError = startupError ?? error.localizedDescription
        }
        await SmokeHarness.seedIfEnabled(store: store)
        do {
            // Desmos is gone: its key row is purged once (StudyGraphMigration).
            try await StudyGraphMigration.run(store: store)
        } catch {
            Self.logger.error("graph migration failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            if let selection = try await store.get(.theme, as: ThemeSelection.self) {
                themeSelection = selection
            }
            // The scheme shared by every Thuban app wins over this app's own saved one.
            if let shared = SharedTheme.load(), shared != themeSelection {
                themeSelection = shared
                try? await store.set(.theme, shared)
            }
            modelPolicy = try await store.get(.modelPolicy, as: ModelPolicy.self) ?? .default
            tutorMayEditGraph = try await store.get(.tutorMayEditGraph, as: Bool.self) ?? true
            showFigureDescriptions = try await store.get(.showFigureDescriptions, as: Bool.self) ?? false
            graphReverseContrast = try await store.get(.graphReverseContrast, as: Bool.self) ?? false
            await migrateCredentialsFromKeychainOnce()
            classes = try await store.allClasses()
            let last = try await store.get(.lastClass, as: ClassID.self)
            await loadSavedClassStates()
            selectedClassID = classes.first { $0.id == last }?.id ?? classes.first?.id
        } catch {
            Self.logger.error("Load failed: \(error.localizedDescription, privacy: .public)")
            startupError = startupError ?? error.localizedDescription
        }
        // First Thuban app to run with sharing seeds the file with its own scheme.
        if SharedTheme.load() == nil { SharedTheme.publish(themeSelection) }
        recomputeTheme()
        // Question-bank defaults (mastery threshold, auto-regenerate, questions per chunk) are read by grading
        // and the import pipeline, so they must be loaded before the first attempt, not only when Settings opens.
        await questionBankSettings.load()
        await refreshConnection()
        isLoaded = true
        startBackgroundPasses()
        Task.detached(priority: .utility) { [engine] in
            try? await engine.warmUp()
        }
        SmokeHarness.startIfEnabled(app: self)
        FigureDump.startIfEnabled(app: self)
        FigureReanalysisLaunch.startIfEnabled(app: self)
        FigureSelfReviewLaunch.startIfEnabled(app: self)
        RegenerateHarness.startIfEnabled(app: self)
        ImportHarness.startIfEnabled(app: self)
    }

    // MARK: Connection

    func refreshConnection() async {
        let wasConnected = connection.isConnected
        connection = await credentials.status()
        // Signing in (after launch) starts the background passes that need the model.
        if isLoaded, !wasConnected, connection.isConnected { startBackgroundPasses() }
    }

    /// The categorizer and the constants check, one after the other (each skips work already done).
    func startBackgroundPasses() {
        Task {
            await categorizeUnclassifiedQuestions()
            await pinConstantsInBankOnce()
            await convertSketchPartsOnce()
        }
    }

    func setAPIKey(_ key: String) async throws {
        try await credentials.setAPIKey(key)
        accountError = nil
        await refreshConnection()
    }

    func setOAuth(_ tokens: OAuthTokens) async throws {
        try await credentials.setOAuth(tokens)
        accountError = nil
        await refreshConnection()
    }

    func disconnect() async {
        do {
            try await credentials.disconnect()
            accountError = nil
        } catch {
            accountError = "Disconnect did not finish: \(error.localizedDescription)"
        }
        await refreshConnection()
    }

    /// A tutor or import request failed because of the credentials: mark rejected OAuth tokens as expired so the
    /// status chip and the account card say "Sign in again" instead of "Connected", and re-read the status.
    func noteCredentialProblem(_ error: ThubanError) async {
        // Only a 401 proves the token itself is dead; a 403 can be a per-request permission problem.
        if case .api(let status, _) = error, status == 401 { await credentials.noteAuthenticationFailure() }
        await refreshConnection()
    }

    // MARK: Theme

    func setThemeSelection(_ selection: ThemeSelection) {
        themeSelection = selection
        recomputeTheme()
        Task { try? await store.set(.theme, selection) }
        SharedTheme.publish(selection)
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        var selection = themeSelection
        selection.mode = mode
        setThemeSelection(selection)
    }

    func selectScheme(id: String) {
        var selection = themeSelection
        selection.schemeId = id
        if id == ColorScheme.customId, selection.custom == nil {
            selection.custom = SchemePresets.default.asCustom()
        }
        setThemeSelection(selection)
    }

    func setCustomScheme(_ scheme: ColorScheme) {
        var selection = themeSelection
        selection.custom = scheme.asCustom(label: scheme.label)
        selection.schemeId = ColorScheme.customId
        setThemeSelection(selection)
    }

    @ObservationIgnored private var sharedThemeObserver: NSObjectProtocol?

    /// Another Thuban app changed the scheme: adopt it (publishing again is a no-op once the file matches).
    private func observeSharedTheme() {
        guard sharedThemeObserver == nil else { return }
        sharedThemeObserver = SharedTheme.observe { [weak self] selection in
            guard let self, self.themeSelection != selection else { return }
            self.setThemeSelection(selection)
        }
    }

    private func observeAppearance() {
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let dark = Self.currentSystemIsDark()
                if dark != self.systemIsDark {
                    self.systemIsDark = dark
                    self.recomputeTheme()
                }
            }
        }
    }

    /// True when macOS itself is dark (independent of any override we apply to `NSApp.appearance`).
    static func currentSystemIsDark() -> Bool {
        // The global preference is authoritative even while we override `NSApp.appearance` for Light/Dark mode.
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    private func recomputeTheme() {
        let resolved = ThemeResolver.resolve(themeSelection, systemIsDark: systemIsDark)
        if resolved != theme {
            theme = resolved
        }
        // Native controls (sheets, menus, text fields) follow the chosen mode too.
        let application = NSApplication.shared
        switch themeSelection.mode {
        case .auto: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
        AppIconRenderer.apply(theme: resolved)
    }

    // MARK: Settings values

    func setModelPolicy(_ policy: ModelPolicy) {
        modelPolicy = policy
        Task { try? await store.set(.modelPolicy, policy) }
    }

    func setShowFigureDescriptions(_ shown: Bool) {
        showFigureDescriptions = shown
        Task { try? await store.set(.showFigureDescriptions, shown) }
    }

    func setTutorMayEditGraph(_ allowed: Bool) {
        tutorMayEditGraph = allowed
        Task { try? await store.set(.tutorMayEditGraph, allowed) }
    }

    func setGraphReverseContrast(_ reversed: Bool) {
        graphReverseContrast = reversed
        Task { try? await store.set(.graphReverseContrast, reversed) }
    }

    /// The graph paper's tokens: the theme itself, or the opposite mode with reverse contrast.
    var graphPaperTheme: ResolvedTheme? {
        guard graphReverseContrast else { return nil }
        var selection = themeSelection
        selection.mode = theme.isDark ? .light : .dark
        return ThemeResolver.resolve(selection, systemIsDark: !theme.isDark)
    }

    // MARK: Classes

    func session(for classId: ClassID) -> ClassSession {
        if let existing = sessions[classId] { return existing }
        let session = ClassSession(classId: classId, app: self)
        sessions[classId] = session
        return session
    }

    func selectClass(_ id: ClassID?) {
        selectedClassID = id
    }

    @discardableResult
    func createClass(name: String, courseCode: String? = nil, term: String? = nil, tutorStyle: TutorStyle = .socratic) async throws -> StudyClass {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThubanError.store("The class needs a name.") }
        let studyClass = StudyClass(
            name: trimmed,
            courseCode: courseCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            term: term?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tutorStyle: tutorStyle,
            sortOrder: (classes.map(\.sortOrder).max() ?? -1) + 1
        )
        try await store.insert(studyClass)
        classes = try await store.allClasses()
        selectedClassID = studyClass.id
        return studyClass
    }

    func renameClass(_ id: ClassID, to name: String) async throws {
        guard var studyClass = classes.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        studyClass.name = trimmed
        try await updateClass(studyClass)
    }

    func updateClass(_ studyClass: StudyClass) async throws {
        try await store.update(studyClass)
        classes = try await store.allClasses()
    }

    func deleteClass(_ id: ClassID, deleteFiles: Bool) async throws {
        var failure: Error?
        do {
            try await store.delete(id, deleteFiles: deleteFiles)
        } catch {
            failure = error
        }
        // Whatever happened, the tabs follow the database: a class whose rows are gone must not stay on screen.
        classes = try await store.allClasses()
        if !classes.contains(where: { $0.id == id }) {
            sessions[id] = nil
            await StudyGraphHost.deleteSavedGraph(store: store, classId: id)
            if selectedClassID == id {
                selectedClassID = classes.first?.id
            }
        }
        if let failure { throw failure }
    }

    /// Persists a new tab order (ids in display order).
    func reorderClasses(_ ids: [ClassID]) async throws {
        try await store.reorderClasses(ids)
        classes = try await store.allClasses()
    }

    func moveClass(_ id: ClassID, before target: ClassID) async {
        var ids = classes.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        let insertAt = ids.firstIndex(of: target) ?? to
        ids.insert(id, at: insertAt)
        try? await reorderClasses(ids)
    }

    // MARK: Commands

    /// Runs a menu/keyboard command: a registered screen handler first, otherwise the shell default.
    func perform(_ command: AppCommand) {
        if commands.perform(command) { return }
        switch command {
        case .newClass:
            isPresentingNewClass = true
        case .importDocuments:
            guard let session = selectedSession else { isPresentingNewClass = true; return }
            session.section = .importDocs
            importPanelRequest += 1
        // The Study commands only act while the Study section is showing; on the bank or import screens the
        // toggles are invisible and ⌘→ / ⌘⇧R would silently re-instantiate the hidden question.
        case .toggleGraph:
            studySession?.showGraph.toggle()
        case .toggleCalculator:
            studySession?.showCalculator.toggle()
        case .toggleKeyboard:
            studySession?.showKeyboard.toggle()
        case .toggleEquations:
            studySession?.showEquations.toggle()
        case .nextQuestion:
            studySession?.next()
        case .regenerate:
            // Templates only (the action bar shows "Regenerate numbers" for .mathTemplate alone); for any other
            // kind a regenerate would just wipe the student's typed answers.
            guard let session = studySession, session.canRegenerate else { return }
            Task { await session.regenerate() }
        case .checkAnswers, .showHint:
            // Implemented by the Study screen through `commands.register`.
            break
        case .openSettings:
            settingsRequest += 1
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
