import XCTest
@testable import ThubanCore

final class FileCredentialStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("thuban-cred-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storage: FileCredentialStorage { FileCredentialStorage(url: directory.appendingPathComponent("credentials.json")) }

    func testRoundTripsAccountsInAPrivateFile() throws {
        let store = storage
        XCTAssertNil(try store.load(account: "oauth"), "nothing stored yet, and no file is created by a read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))

        try store.save(Data("token-1".utf8), account: "oauth")
        try store.save(Data("sk-x".utf8), account: "apikey")
        XCTAssertEqual(try store.load(account: "oauth"), Data("token-1".utf8))
        XCTAssertEqual(try store.load(account: "apikey"), Data("sk-x".utf8))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o600, "readable by the owner only")

        try store.save(Data("token-2".utf8), account: "oauth")
        XCTAssertEqual(try store.load(account: "oauth"), Data("token-2".utf8), "save replaces")

        try store.delete(account: "oauth")
        XCTAssertNil(try store.load(account: "oauth"))
        XCTAssertEqual(try store.load(account: "apikey"), Data("sk-x".utf8), "other accounts survive a delete")
        try store.delete(account: "apikey")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "the file goes with the last account")
        try store.delete(account: "apikey")
    }

    func testCredentialStoreWorksOnTheFile() async throws {
        let store = CredentialStore(keychain: storage)
        try await store.setAPIKey("sk-file")
        let auth = try await store.currentAuth()
        XCTAssertEqual(auth, .apiKey("sk-file"))

        let again = CredentialStore(keychain: storage)
        let reread = try await again.currentAuth()
        XCTAssertEqual(reread, .apiKey("sk-file"), "a fresh store reads the same file")
        try await again.disconnect()
        let status = await again.status()
        XCTAssertEqual(status, .notConnected)
    }

    func testMigrationMovesLegacyItemsAndClearsThem() throws {
        let legacy = InMemoryKeychain(items: [Keychain.oauthAccount: Data("legacy-oauth".utf8)])
        let target = storage
        XCTAssertTrue(CredentialStore.migrateFromLoginKeychain(into: target, legacy: legacy))
        XCTAssertEqual(try target.load(account: Keychain.oauthAccount), Data("legacy-oauth".utf8))
        XCTAssertTrue(legacy.accounts.isEmpty, "the Keychain item is deleted so it never prompts again")
        XCTAssertFalse(CredentialStore.migrateFromLoginKeychain(into: target, legacy: legacy), "nothing left to move")

        // An existing file credential is never overwritten by a stale Keychain copy.
        let stale = InMemoryKeychain(items: [Keychain.oauthAccount: Data("older".utf8)])
        XCTAssertFalse(CredentialStore.migrateFromLoginKeychain(into: target, legacy: stale))
        XCTAssertEqual(try target.load(account: Keychain.oauthAccount), Data("legacy-oauth".utf8))
    }
}
