import Foundation
import GRDB
import os

/// Where a `Store` keeps its database and the files that rows point at. `ImportedDocument.storedPath` is relative
/// to `documents`; `Figure.originalPath` is relative to `figures`.
public struct StoreLocations: Sendable, Equatable {
    /// The SQLite file, or `nil` for an in-memory database.
    public var database: URL?
    /// Root of imported source files.
    public var documents: URL
    /// Root of extracted figure PNGs.
    public var figures: URL

    public init(database: URL?, documents: URL, figures: URL) {
        self.database = database
        self.documents = documents
        self.figures = figures
    }

    /// The app's standard locations under `AppPaths`.
    public static var standard: StoreLocations {
        StoreLocations(database: AppPaths.database, documents: AppPaths.documents, figures: AppPaths.figures)
    }

    /// The standard document and figure directories with an in-memory database.
    public static var memory: StoreLocations {
        StoreLocations(database: nil, documents: AppPaths.documents, figures: AppPaths.figures)
    }

    /// A fresh, unique directory under the system temporary directory. Used by tests and previews.
    public static func temporary(inMemoryDatabase: Bool = false) throws -> StoreLocations {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThubanStore-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw ThubanError.store("Could not create temporary store at \(root.path): \(error.localizedDescription)")
        }
        return StoreLocations(
            database: inMemoryDatabase ? nil : root.appendingPathComponent(AppPaths.databaseFilename, isDirectory: false),
            documents: root.appendingPathComponent("documents", isDirectory: true),
            figures: root.appendingPathComponent("figures", isDirectory: true)
        )
    }
}

/// The GRDB persistence layer. One `Store` owns one SQLite database (a WAL `DatabasePool` on disk, a
/// `DatabaseQueue` in memory) and knows where the document and figure files live. Every repository protocol of
/// the architecture contract is implemented as an extension on this class; all repository calls are
/// `async throws`, run on GRDB's own dispatch queues, and surface failures as `ThubanError.store`.
public final class Store: Sendable {
    /// The database connection. Public so that other modules can run their own observations or reads; prefer the
    /// repository methods for writes.
    public let queue: any DatabaseWriter
    /// Where this store's database and files live.
    public let locations: StoreLocations

    static let logger = Logger(subsystem: "com.thuban.study", category: "store")

    private init(queue: any DatabaseWriter, locations: StoreLocations) {
        self.queue = queue
        self.locations = locations
    }

    // MARK: Opening

    /// Opens (creating and migrating if needed) the database at `url`, or at `AppPaths.database` when `nil`.
    /// Document and figure files are resolved under `AppPaths`. A `url` whose path ends in `:memory:` opens an
    /// in-memory database.
    public static func open(at url: URL? = nil) throws -> Store {
        guard let url else {
            try AppPaths.ensureDirectories()
            return try open(.standard)
        }
        if url.path.hasSuffix(":memory:") { return try open(.memory) }
        return try open(StoreLocations(database: url, documents: AppPaths.documents, figures: AppPaths.figures))
    }

    /// An in-memory store whose files resolve under `AppPaths`. Intended for tests and previews.
    public static func inMemory() throws -> Store {
        try open(.memory)
    }

    /// Opens a store at explicit locations, creating the directories and running migrations.
    public static func open(_ locations: StoreLocations) throws -> Store {
        try ensureDirectories(for: locations)
        let writer = try makeWriter(for: locations)
        do {
            try migrator.migrate(writer)
        } catch {
            throw wrap(error, context: "Migrating database")
        }
        logger.debug("Opened store at \(locations.database?.path ?? ":memory:", privacy: .public)")
        return Store(queue: writer, locations: locations)
    }

    private static func makeWriter(for locations: StoreLocations) throws -> any DatabaseWriter {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "com.thuban.study.store"
        do {
            guard let database = locations.database else {
                return try DatabaseQueue(configuration: configuration)
            }
            return try DatabasePool(path: database.path, configuration: configuration)
        } catch {
            throw wrap(error, context: "Opening database")
        }
    }

    /// Creates the database's parent and the file directories. An in-memory store touches no directories; the
    /// file APIs tolerate missing ones.
    private static func ensureDirectories(for locations: StoreLocations) throws {
        guard let database = locations.database else { return }
        let directories = [database.deletingLastPathComponent(), locations.documents, locations.figures]
        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ThubanError.store("Could not create \(directory.path): \(error.localizedDescription)")
            }
        }
    }

    /// Closes the underlying connections. The store must not be used afterwards.
    public func close() throws {
        do {
            try queue.close()
        } catch {
            throw Store.wrap(error, context: "Closing database")
        }
    }

    // MARK: Transactions

    /// Runs `updates` in one write transaction and maps failures to `ThubanError`.
    func write<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await queue.write(updates)
        } catch {
            throw Store.wrap(error)
        }
    }

    /// Runs `value` in a read transaction and maps failures to `ThubanError`.
    func read<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await queue.read(value)
        } catch {
            throw Store.wrap(error)
        }
    }

    /// Maps any error thrown by GRDB or Foundation into a `ThubanError`.
    static func wrap(_ error: Error, context: String? = nil) -> ThubanError {
        if let thuban = error as? ThubanError { return thuban }
        let detail: String
        if let databaseError = error as? DatabaseError {
            detail = "SQLite \(databaseError.resultCode.rawValue): \(databaseError.message ?? "unknown error")"
        } else if let recordError = error as? RecordError {
            detail = String(describing: recordError)
        } else if error is CancellationError {
            return .cancelled
        } else {
            detail = error.localizedDescription
        }
        if let context { return .store("\(context): \(detail)") }
        return .store(detail)
    }

    // MARK: Files

    /// Absolute URL of a stored document, or `nil` when `storedPath` would escape the documents directory.
    public func documentURL(_ storedPath: String) -> URL? {
        Store.resolve(storedPath, under: locations.documents)
    }

    /// Absolute URL of a stored figure, or `nil` when `originalPath` would escape the figures directory.
    public func figureURL(_ originalPath: String) -> URL? {
        Store.resolve(originalPath, under: locations.figures)
    }

    /// Joins a relative path onto `root`, refusing paths that resolve outside it.
    static func resolve(_ relativePath: String, under root: URL) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let rootPath = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    /// Deletes the given relative files under `root`, ignoring ones that no longer exist, and prunes directories
    /// left empty. Returns the paths that could not be removed.
    static func removeFiles(_ relativePaths: [String], under root: URL) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []
        for relativePath in relativePaths {
            guard let url = resolve(relativePath, under: root) else {
                failures.append(relativePath)
                continue
            }
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                pruneEmptyDirectories(from: url.deletingLastPathComponent(), upTo: root)
            } catch {
                logger.error("Could not delete \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failures.append(relativePath)
            }
        }
        return failures
    }

    private static func pruneEmptyDirectories(from directory: URL, upTo root: URL) {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path != rootPath, current.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path), contents.isEmpty else { return }
            guard (try? fm.removeItem(at: current)) != nil else { return }
            current = current.deletingLastPathComponent()
        }
    }
}
