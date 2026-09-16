import Foundation
import GRDB
import ZIPFoundation

extension Store {
    /// Bytes used on disk: the database (including its WAL and shared-memory files) plus every stored document
    /// and figure. An in-memory database contributes only its files.
    public func storageSize() async throws -> Int64 {
        let locations = self.locations
        return try await Task.detached(priority: .utility) {
            var total: Int64 = 0
            if let database = locations.database {
                for suffix in ["", "-wal", "-shm"] {
                    let url = URL(fileURLWithPath: database.path + suffix)
                    total += try Store.fileSize(at: url)
                }
            }
            total += try Store.directorySize(at: locations.documents)
            total += try Store.directorySize(at: locations.figures)
            return total
        }.value
    }

    /// Writes a zip archive containing a consistent snapshot of the database (`thuban.sqlite`) and the
    /// `documents/` and `figures/` directories. An existing file at `url` is replaced.
    public func exportArchive(to url: URL) async throws {
        let queue = self.queue
        let locations = self.locations
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory
                .appendingPathComponent("ThubanExport-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try Store.snapshotDatabase(queue, to: staging.appendingPathComponent(AppPaths.databaseFilename))
                try Store.copyDirectoryIfPresent(locations.documents, to: staging.appendingPathComponent("documents"))
                try Store.copyDirectoryIfPresent(locations.figures, to: staging.appendingPathComponent("figures"))
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.zipItem(at: staging, to: url, shouldKeepParent: false, compressionMethod: .deflate)
            } catch {
                throw Store.wrap(error, context: "Exporting archive")
            }
        }.value
    }

    // MARK: Helpers

    private static func snapshotDatabase(_ source: any DatabaseWriter, to url: URL) throws {
        let destination = try DatabaseQueue(path: url.path)
        try source.backup(to: destination)
        try destination.close()
    }

    private static func copyDirectoryIfPresent(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        do {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw ThubanError.store("Could not read size of \(url.path): \(error.localizedDescription)")
        }
    }

    private static func directorySize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            } catch {
                throw ThubanError.store("Could not read size of \(file.path): \(error.localizedDescription)")
            }
        }
        return total
    }
}
