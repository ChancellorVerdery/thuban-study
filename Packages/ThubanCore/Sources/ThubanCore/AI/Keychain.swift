import Foundation
import Security
import os

/// Secret storage keyed by account name. The production implementation is the macOS Keychain; tests use
/// `InMemoryKeychain`.
public protocol KeychainStorage: Sendable {
    func save(_ data: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

/// Static convenience over the app's Keychain service (`com.thuban.study`).
public enum Keychain {
    public static let service = "com.thuban.study"
    public static let oauthAccount = "oauth"
    public static let apiKeyAccount = "apikey"

    private static let storage = SecurityKeychain(service: service)
    private static let logger = Logger(subsystem: "com.thuban.study", category: "Keychain")

    public static func save(_ data: Data, account: String) throws {
        try storage.save(data, account: account)
    }

    public static func load(account: String) throws -> Data? {
        try storage.load(account: account)
    }

    /// Removes the item; a missing item is not an error and other failures are logged.
    public static func delete(account: String) {
        do {
            try storage.delete(account: account)
        } catch {
            logger.error("Keychain delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// `kSecClassGenericPassword` items under one service in the login keychain. Access is governed by that keychain's
/// per-item ACL, which trusts the binary that created the item: an ad-hoc-signed development build changes identity
/// on every rebuild, so macOS asks the student to allow the first read. A refused prompt (or a locked keychain)
/// surfaces as `ThubanError.keychainDenied` so the app can point at Settings instead of reporting a storage error.
/// (`kSecAttrAccessible` is not set: the login keychain ignores it; it only applies to the data-protection keychain,
/// which needs a signed app with an application identifier.)
public struct SecurityKeychain: KeychainStorage {
    public let service: String

    public init(service: String = Keychain.service) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Self.error(updateStatus, "save") }
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Self.error(addStatus, "save") }
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Self.error(status, "load")
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete") }
    }

    /// Statuses that mean the OS would not let this binary at the item (denied prompt, locked or non-interactive
    /// keychain) rather than a broken item.
    static let accessDeniedStatuses: Set<OSStatus> = [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled]

    private static func error(_ status: OSStatus, _ operation: String) -> ThubanError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        if accessDeniedStatuses.contains(status) { return .keychainDenied(message) }
        return .store("Keychain \(operation) failed: \(message)")
    }
}

/// Thread-safe in-memory `KeychainStorage` for tests and previews.
public final class InMemoryKeychain: KeychainStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init(items: [String: Data] = [:]) {
        self.items = items
    }

    public func save(_ data: Data, account: String) throws {
        lock.withLock { items[account] = data }
    }

    public func load(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }

    /// Every stored account name.
    public var accounts: [String] { lock.withLock { items.keys.sorted() } }
}
