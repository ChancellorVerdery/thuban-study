import Foundation
import ThubanCore
import os
internal import GraphModel
internal import GraphTypes

/// A class's graphs on disk (STUDY_INTEGRATION.md §7): the settings row `classGraph.<class id>` holds
///
///     { "format": "thuban-study-graph", "version": 1, "twoD": {…}, "threeD": {…}, "tutorIDs": [...] }
///
/// where each half is exactly what `GraphFile.encode` writes for a `.thgraph` file (so it opens in Thuban Graph)
/// and is read back through `GraphFile.decode` (its format check and migrations). Written 400 ms after the last
/// change, like `classState.<id>`. A row that cannot be read starts empty graphs without losing the row
/// (`StudyGraphStore.performLoad`).
enum StudyGraphRecord {
    static let format = "thuban-study-graph"
    static let version = 1

    static func key(for classId: ClassID) -> SettingsKey { SettingsKey("classGraph.\(classId.raw)") }
    /// Where an unreadable row is copied before the class's graph is saved over it.
    static func backupKey(for classId: ClassID) -> SettingsKey { SettingsKey("classGraph.\(classId.raw).unreadable") }

    struct Contents: Equatable {
        var twoD: GraphDocument
        var threeD: GraphDocument
        var tutorIDs: Set<String>
    }

    static func encode(_ contents: Contents) throws -> JSONValue {
        let twoD = try JSONValue(data: GraphFile.encode(contents.twoD))
        let threeD = try JSONValue(data: GraphFile.encode(contents.threeD))
        return .object([
            "format": .string(format),
            "version": .number(Double(version)),
            "twoD": twoD,
            "threeD": threeD,
            "tutorIDs": .array(contents.tutorIDs.sorted().map { .string($0) }),
        ])
    }

    enum Failure: Error, LocalizedError {
        case unknownFormat
        case tooNew(Int)
        var errorDescription: String? {
            switch self {
            case .unknownFormat: return "not a Thuban Study graph record"
            case .tooNew(let version): return "saved by a newer Thuban Study (graph record version \(version))"
            }
        }
    }

    /// Reads a stored row: the current record, or a legacy array of Study `GraphExpression` rows (the Desmos-era
    /// in-memory model, converted row by row).
    static func decode(_ value: JSONValue) throws -> Contents {
        if let legacy = value.arrayValue {
            return try GraphExpressionConverter.contents(fromLegacyRows: JSONValue.array(legacy).data())
        }
        guard value["format"]?.stringValue == format else { throw Failure.unknownFormat }
        let stored = value["version"]?.intValue ?? 1
        guard stored <= version else { throw Failure.tooNew(stored) }
        func document(_ key: String, _ mode: GraphMode) throws -> GraphDocument {
            guard let half = value[key], !half.isNull else { return StudyGraphHost.emptyDocument(mode == .threeD ? .threeD : .twoD) }
            var document = try GraphFile.decode(half.data())
            document.mode = mode
            return document
        }
        let ids = (value["tutorIDs"]?.arrayValue ?? []).compactMap(\.stringValue)
        return Contents(twoD: try document("twoD", .twoD), threeD: try document("threeD", .threeD), tutorIDs: Set(ids))
    }
}

/// Loads and saves one host's record.
@MainActor
final class StudyGraphStore {
    private static let logger = Logger(subsystem: "com.thuban.study", category: "graph")
    let store: Store
    let classId: ClassID
    weak var host: StudyGraphHost?
    private var saveTask: Task<Void, Never>?
    private var lastSaved: JSONValue?
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    /// The stored row could not be read and could not be backed up, or a newer Study wrote it: never write it.
    private(set) var isReadOnly = false

    init(store: Store, classId: ClassID, host: StudyGraphHost) {
        self.store = store
        self.classId = classId
        self.host = host
    }

    /// Starts reading the saved record (once). Synchronous, so a tool call or edit that follows can wait for it.
    func startLoad() {
        guard loadTask == nil else { return }
        loadTask = Task { await self.performLoad() }
    }

    /// Waits for the load (tool calls arriving while a class opens).
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    /// A stored row that cannot be read is never overwritten blindly. A record written by a newer Study, or one the
    /// store could not fetch, leaves saving off for this launch (edits stay in memory). Any other unreadable row is
    /// first copied to `classGraph.<id>.unreadable`; saving resumes only once that copy is written.
    private func performLoad() async {
        defer {
            loaded = true
            host?.loadFinished()
        }
        let value: JSONValue
        do {
            guard let stored = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self) else { return }
            value = stored
        } catch {
            isReadOnly = true
            Self.logger.error("class graph could not be read; not saving it this launch: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            let contents = try StudyGraphRecord.decode(value)
            host?.restore(twoD: contents.twoD, threeD: contents.threeD, tutorIDs: contents.tutorIDs)
            lastSaved = value
        } catch StudyGraphRecord.Failure.tooNew(let version) {
            isReadOnly = true
            Self.logger.warning("class graph saved by a newer Study (record v\(version, privacy: .public)); kept, not saving this launch")
        } catch {
            do {
                try await store.set(StudyGraphRecord.backupKey(for: classId), value)
                Self.logger.warning("class graph unreadable (\(error.localizedDescription, privacy: .public)); copied aside, starting empty")
            } catch {
                isReadOnly = true
                Self.logger.error("class graph unreadable and its copy failed; not saving it this launch")
            }
        }
    }

    func scheduleSave() {
        guard loaded, !isReadOnly else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            await self.write()
        }
    }

    /// Writes now, dropping a pending debounced save (quit).
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        await write()
    }

    /// Never runs in a cancelled task (the store's write would throw `CancellationError`).
    private func write() async {
        guard loaded, !isReadOnly, let host else { return }
        do {
            let value = try StudyGraphRecord.encode(StudyGraphRecord.Contents(
                twoD: host.twoD.document, threeD: host.threeD.document, tutorIDs: host.tutorIDs))
            guard value != lastSaved else { return }
            try await store.set(StudyGraphRecord.key(for: classId), value)
            lastSaved = value
        } catch {
            Self.logger.error("save class graph failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension StudyGraphHost {
    /// Connects the host to its class's saved graphs and starts reading them, synchronously: a tool call or save
    /// that follows waits for the read instead of being replaced by it. Later changes are saved (debounced).
    /// Idempotent.
    public func connect(store: Store, classId: ClassID) {
        guard persistence == nil else { return }
        let persistence = StudyGraphStore(store: store, classId: classId, host: self)
        self.persistence = persistence
        persistence.startLoad()
    }

    /// `connect`, then waits until the saved graphs are in the sessions.
    public func attach(store: Store, classId: ClassID) async {
        connect(store: store, classId: classId)
        await waitUntilLoaded()
    }

    /// Waits until the saved graphs are in the sessions (at once when not connected).
    public func waitUntilLoaded() async {
        await persistence?.waitUntilLoaded()
    }

    /// Writes pending changes now (quit).
    public func saveNow() async {
        await persistence?.saveNow()
    }

    /// Removes a class's saved graphs (the class was deleted), with any copy of an unreadable row.
    public static func deleteSavedGraph(store: Store, classId: ClassID) async {
        try? await store.remove(StudyGraphRecord.key(for: classId))
        try? await store.remove(StudyGraphRecord.backupKey(for: classId))
    }
}

/// One-shot launch migration (STUDY_INTEGRATION.md §7): Study no longer uses Desmos, so the `desmosKey` settings
/// row is deleted. No graph state was ever persisted in the Desmos era, so nothing else needs converting.
/// Idempotent, guarded by the settings row `migrations.graphKit = 1`.
public enum StudyGraphMigration {
    public static let marker = SettingsKey("migrations.graphKit")
    /// Settings rows of the Desmos era, purged by the migration (the only place their names survive).
    public static let purgedKeys: [SettingsKey] = [SettingsKey("desmosKey")]

    /// Runs the migration unless it already ran; returns true when it did something.
    @discardableResult
    public static func run(store: Store) async throws -> Bool {
        if try await store.get(marker, as: Int.self) == 1 { return false }
        for key in purgedKeys { try await store.remove(key) }
        try await store.set(marker, 1)
        return true
    }
}
