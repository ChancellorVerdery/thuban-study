import Foundation
import os

/// Credentials in a private file instead of the login Keychain. The Keychain's per-item ACL trusts the binary
/// that created an item, and an ad-hoc-signed build changes identity on every rebuild, so macOS asked for
/// permission at every launch. The file (`credentials.json` in the app's data folder) is created with mode 0600,
/// so it is readable by the student's account only, and it is not part of the export archive.
public struct FileCredentialStorage: KeychainStorage {
    public let url: URL
    private static let logger = Logger(subsystem: "com.thuban.study", category: "credentials")
    private static let lock = NSLock()

    /// Default: `AppPaths.credentials`.
    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.credentials
    }

    public func save(_ data: Data, account: String) throws {
        try Self.lock.withLock {
            var items = try readAll()
            items[account] = data.base64EncodedString()
            try writeAll(items)
        }
    }

    public func load(account: String) throws -> Data? {
        try Self.lock.withLock {
            guard let encoded = try readAll()[account] else { return nil }
            guard let data = Data(base64Encoded: encoded) else {
                throw ThubanError.store("The stored credential for \(account) is unreadable.")
            }
            return data
        }
    }

    public func delete(account: String) throws {
        try Self.lock.withLock {
            var items = try readAll()
            guard items.removeValue(forKey: account) != nil else { return }
            if items.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try writeAll(items)
            }
        }
    }

    // MARK: File

    private func readAll() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ThubanError.keychainDenied("the credentials file is not readable (\(url.lastPathComponent))")
        } catch {
            throw ThubanError.store("Could not read the credentials file: \(error.localizedDescription)")
        }
    }

    private func writeAll(_ items: [String: String]) throws {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            // Atomic write, then tighten the mode (a freshly written file inherits the umask, usually 0644).
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ThubanError.store("Could not write the credentials file: \(error.localizedDescription)")
        }
    }
}

extension AppPaths {
    /// The credentials file (OAuth tokens or API key), mode 0600, outside the export archive.
    public static var credentials: URL { baseDirectory.appendingPathComponent("credentials.json", isDirectory: false) }
}

extension CredentialStore {
    /// Moves credentials an earlier build kept in the login Keychain into `target`, then removes the Keychain items
    /// so macOS never asks about them again. Returns true when something was moved. Reading the Keychain may
    /// prompt once; the caller records that migration ran so a refused prompt is never repeated.
    public static func migrateFromLoginKeychain(into target: KeychainStorage, legacy: KeychainStorage = SecurityKeychain()) -> Bool {
        var moved = false
        for account in [Keychain.oauthAccount, Keychain.apiKeyAccount] {
            guard (try? target.load(account: account)) == nil else { continue }
            guard let data = try? legacy.load(account: account) else { continue }
            do {
                try target.save(data, account: account)
                try? legacy.delete(account: account)
                moved = true
            } catch {
                Logger(subsystem: "com.thuban.study", category: "credentials")
                    .error("Could not move \(account, privacy: .public) out of the Keychain: \(error.localizedDescription, privacy: .public)")
            }
        }
        return moved
    }
}
