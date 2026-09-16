import Foundation

/// Where the app keeps its data. Defaults to `~/Library/Application Support/Thuban Study`; the `THUBAN_HOME`
/// environment variable overrides the base directory (used by tests and for portable installs).
public enum AppPaths {
    /// Environment variable that overrides `baseDirectory`.
    public static let homeOverrideVariable = "THUBAN_HOME"

    public static let databaseFilename = "thuban.sqlite"

    /// Root of all app data.
    public static var baseDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[homeOverrideVariable],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return support.appendingPathComponent("Thuban Study", isDirectory: true)
    }

    /// The GRDB SQLite database.
    public static var database: URL { baseDirectory.appendingPathComponent(databaseFilename, isDirectory: false) }

    /// Imported source files (`ImportedDocument.storedPath` is relative to this).
    public static var documents: URL { baseDirectory.appendingPathComponent("documents", isDirectory: true) }

    /// Extracted figure PNGs (`Figure.originalPath` is relative to this).
    public static var figures: URL { baseDirectory.appendingPathComponent("figures", isDirectory: true) }

    /// Data exports (zips).
    public static var exports: URL { baseDirectory.appendingPathComponent("exports", isDirectory: true) }

    /// Every directory the app writes into.
    public static var allDirectories: [URL] { [baseDirectory, documents, figures, exports] }

    /// Creates the base directory and its subdirectories if they do not exist.
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for url in allDirectories {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw ThubanError.store("Could not create \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Absolute URL of a stored document.
    public static func documentURL(_ storedPath: String) -> URL {
        documents.appendingPathComponent(storedPath, isDirectory: false)
    }

    /// Absolute URL of a stored figure.
    public static func figureURL(_ originalPath: String) -> URL {
        figures.appendingPathComponent(originalPath, isDirectory: false)
    }
}
