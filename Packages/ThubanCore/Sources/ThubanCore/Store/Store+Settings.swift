import Foundation
import GRDB

extension Store: SettingsRepository {
    public func get<T: Codable>(_ key: SettingsKey, as type: T.Type) async throws -> T? {
        let raw = key.rawValue
        let json = try await read { db in
            try SettingRecord.fetchOne(db, key: raw)?.value
        }
        guard let json else { return nil }
        do {
            return try Store.settingsDecoder.decode(SettingEnvelope<T>.self, from: Data(json.utf8)).v
        } catch {
            throw ThubanError.store("Setting '\(raw)' is not a \(T.self): \(error.localizedDescription)")
        }
    }

    public func set<T: Codable>(_ key: SettingsKey, _ value: T) async throws {
        let raw = key.rawValue
        let json: String
        do {
            json = String(decoding: try Store.settingsEncoder.encode(SettingEnvelope(v: value)), as: UTF8.self)
        } catch {
            throw ThubanError.store("Setting '\(raw)' could not be encoded: \(error.localizedDescription)")
        }
        try await write { db in
            try SettingRecord(key: raw, value: json).save(db)
        }
    }

    /// Deletes a setting; a no-op when it is absent.
    public func remove(_ key: SettingsKey) async throws {
        let raw = key.rawValue
        try await write { db in _ = try SettingRecord.deleteOne(db, key: raw) }
    }

    /// Every stored key.
    public func settingsKeys() async throws -> [SettingsKey] {
        try await read { db in
            try String.fetchAll(db, sql: "SELECT key FROM settings ORDER BY key").map(SettingsKey.init(rawValue:))
        }
    }

    static var settingsEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var settingsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Wraps a setting so that scalars (strings, numbers, booleans) are always stored as a JSON object.
private struct SettingEnvelope<T: Codable>: Codable {
    var v: T
}
