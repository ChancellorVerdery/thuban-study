import Foundation
import GRDB

/// A class's equation sheet: ordered groups holding ordered entries. Positions are dense (0, 1, 2, …) within their
/// parent; every move rewrites the positions of the lists it touches.
public protocol EquationSheetRepository: Sendable {
    /// The whole sheet of a class, groups and entries in order (empty when the class has none).
    func equationSheet(for classId: ClassID) async throws -> EquationSheet
    /// Appends a group at the end of the class's sheet.
    @discardableResult
    func addEquationGroup(named name: String, to classId: ClassID) async throws -> EquationGroup
    func renameEquationGroup(_ id: EquationGroupID, to name: String) async throws
    /// Removes the group and, through the cascading foreign key, its entries.
    func deleteEquationGroup(_ id: EquationGroupID) async throws
    /// Moves a group to `index` (clamped) among its class's groups.
    func moveEquationGroup(_ id: EquationGroupID, to index: Int) async throws
    /// Inserts an entry into its group at `index` (clamped; `nil` appends). Its `position` is assigned.
    @discardableResult
    func addEquationEntry(_ entry: EquationEntry, at index: Int?) async throws -> EquationEntry
    /// Saves name, equations and note. A changed `groupId` moves the entry to the end of that group.
    func updateEquationEntry(_ entry: EquationEntry) async throws
    func deleteEquationEntry(_ id: EquationEntryID) async throws
    /// Moves an entry to `index` (clamped) in `groupId` (its own group or another group of the same class).
    func moveEquationEntry(_ id: EquationEntryID, to groupId: EquationGroupID, index: Int) async throws
    /// Moves an entry into `groupId` next to another entry of that group (or to its end), resolved against the
    /// group's full stored order, so a position picked in a filtered view lands where the user saw it.
    func moveEquationEntry(_ id: EquationEntryID, to groupId: EquationGroupID, placement: EquationEntryPlacement) async throws
    /// Moves an entry `delta` places within its group, from its current stored position (clamped).
    func moveEquationEntry(_ id: EquationEntryID, by delta: Int) async throws
    /// Moves a group `delta` places among its class's groups, from its current stored position (clamped).
    func moveEquationGroup(_ id: EquationGroupID, by delta: Int) async throws
}

/// Where a moved entry goes, relative to another entry of the target group.
public enum EquationEntryPlacement: Sendable, Equatable {
    case before(EquationEntryID)
    case after(EquationEntryID)
    /// At the end of the group (also the fallback when the anchor is not in the group).
    case end
}

extension Store: EquationSheetRepository {
    public func equationSheet(for classId: ClassID) async throws -> EquationSheet {
        try await read { db in
            let groups = try EquationGroup
                .filter(Col.classId == classId)
                .order(Col.position, Col.createdAt, Col.id)
                .fetchAll(db)
            guard !groups.isEmpty else { return EquationSheet(classId: classId) }
            let entries = try EquationEntry
                .filter(groups.map(\.id).contains(Col.groupId))
                .order(Col.position, Col.createdAt, Col.id)
                .fetchAll(db)
            let byGroup = Dictionary(grouping: entries, by: \.groupId)
            return EquationSheet(classId: classId, sections: groups.map {
                EquationSheet.Section(group: $0, entries: byGroup[$0.id] ?? [])
            })
        }
    }

    @discardableResult
    public func addEquationGroup(named name: String, to classId: ClassID) async throws -> EquationGroup {
        try await write { db in
            let next = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM equation_groups WHERE classId = ?", arguments: [classId]
            ) ?? 0
            let group = EquationGroup(classId: classId, name: name, position: next)
            try group.insert(db)
            return group
        }
    }

    public func renameEquationGroup(_ id: EquationGroupID, to name: String) async throws {
        try await write { db in
            try db.execute(sql: "UPDATE equation_groups SET name = ? WHERE id = ?", arguments: [name, id])
            guard db.changesCount > 0 else { throw ThubanError.store("No equation group \(id.raw)") }
        }
    }

    public func deleteEquationGroup(_ id: EquationGroupID) async throws {
        try await write { db in
            guard let group = try EquationGroup.fetchOne(db, id: id) else { return }
            _ = try EquationGroup.deleteOne(db, id: id)
            try Store.renumberGroups(db, classId: group.classId)
        }
    }

    public func moveEquationGroup(_ id: EquationGroupID, to index: Int) async throws {
        try await write { db in
            guard let group = try EquationGroup.fetchOne(db, id: id) else {
                throw ThubanError.store("No equation group \(id.raw)")
            }
            var ids = try Store.groupIds(db, classId: group.classId)
            ids.removeAll { $0 == id }
            ids.insert(id, at: min(max(0, index), ids.count))
            try Store.writePositions(db, table: "equation_groups", ids: ids.map(\.raw))
        }
    }

    @discardableResult
    public func addEquationEntry(_ entry: EquationEntry, at index: Int?) async throws -> EquationEntry {
        try await write { db in
            guard try EquationGroup.fetchOne(db, id: entry.groupId) != nil else {
                throw ThubanError.store("No equation group \(entry.groupId.raw)")
            }
            var ids = try Store.entryIds(db, groupId: entry.groupId)
            let position = index.map { min(max(0, $0), ids.count) } ?? ids.count
            var inserted = entry
            inserted.position = position
            try inserted.insert(db)
            ids.insert(entry.id, at: position)
            try Store.writePositions(db, table: "equation_entries", ids: ids.map(\.raw))
            return inserted
        }
    }

    public func updateEquationEntry(_ entry: EquationEntry) async throws {
        try await write { db in
            guard let existing = try EquationEntry.fetchOne(db, id: entry.id) else {
                throw ThubanError.store("No equation entry \(entry.id.raw)")
            }
            var updated = entry
            if existing.groupId != entry.groupId {
                guard try EquationGroup.fetchOne(db, id: entry.groupId) != nil else {
                    throw ThubanError.store("No equation group \(entry.groupId.raw)")
                }
                updated.position = try Store.entryIds(db, groupId: entry.groupId).count
                try updated.update(db)
                try Store.renumberEntries(db, groupId: existing.groupId)
            } else {
                updated.position = existing.position
                try updated.update(db)
            }
        }
    }

    public func deleteEquationEntry(_ id: EquationEntryID) async throws {
        try await write { db in
            guard let entry = try EquationEntry.fetchOne(db, id: id) else { return }
            _ = try EquationEntry.deleteOne(db, id: id)
            try Store.renumberEntries(db, groupId: entry.groupId)
        }
    }

    public func moveEquationEntry(_ id: EquationEntryID, to groupId: EquationGroupID, index: Int) async throws {
        try await write { db in try Store.moveEntry(db, id, to: groupId, index: index) }
    }

    public func moveEquationEntry(_ id: EquationEntryID, to groupId: EquationGroupID,
                                  placement: EquationEntryPlacement) async throws {
        try await write { db in
            var ids = try Store.entryIds(db, groupId: groupId)
            ids.removeAll { $0 == id }
            let index: Int
            switch placement {
            case .before(let anchor): index = ids.firstIndex(of: anchor) ?? ids.count
            case .after(let anchor): index = ids.firstIndex(of: anchor).map { $0 + 1 } ?? ids.count
            case .end: index = ids.count
            }
            try Store.moveEntry(db, id, to: groupId, index: index)
        }
    }

    public func moveEquationEntry(_ id: EquationEntryID, by delta: Int) async throws {
        try await write { db in
            guard let entry = try EquationEntry.fetchOne(db, id: id) else {
                throw ThubanError.store("No equation entry \(id.raw)")
            }
            var ids = try Store.entryIds(db, groupId: entry.groupId)
            guard let current = ids.firstIndex(of: id) else { return }
            ids.remove(at: current)
            ids.insert(id, at: min(max(0, current + delta), ids.count))
            try Store.writePositions(db, table: "equation_entries", ids: ids.map(\.raw))
        }
    }

    public func moveEquationGroup(_ id: EquationGroupID, by delta: Int) async throws {
        try await write { db in
            guard let group = try EquationGroup.fetchOne(db, id: id) else {
                throw ThubanError.store("No equation group \(id.raw)")
            }
            var ids = try Store.groupIds(db, classId: group.classId)
            guard let current = ids.firstIndex(of: id) else { return }
            ids.remove(at: current)
            ids.insert(id, at: min(max(0, current + delta), ids.count))
            try Store.writePositions(db, table: "equation_groups", ids: ids.map(\.raw))
        }
    }

    // MARK: Positions

    /// Moves an entry to `index` (clamped, counted without the entry itself) in `groupId`, within one transaction.
    private static func moveEntry(_ db: Database, _ id: EquationEntryID, to groupId: EquationGroupID, index: Int) throws {
        guard let entry = try EquationEntry.fetchOne(db, id: id) else {
            throw ThubanError.store("No equation entry \(id.raw)")
        }
        guard let source = try EquationGroup.fetchOne(db, id: entry.groupId),
              let target = try EquationGroup.fetchOne(db, id: groupId) else {
            throw ThubanError.store("No equation group \(groupId.raw)")
        }
        guard source.classId == target.classId else {
            throw ThubanError.store("An entry cannot move to another class's sheet")
        }
        if entry.groupId != groupId {
            try db.execute(sql: "UPDATE equation_entries SET groupId = ? WHERE id = ?", arguments: [groupId, id])
            try renumberEntries(db, groupId: entry.groupId)
        }
        var ids = try entryIds(db, groupId: groupId)
        ids.removeAll { $0 == id }
        ids.insert(id, at: min(max(0, index), ids.count))
        try writePositions(db, table: "equation_entries", ids: ids.map(\.raw))
    }

    private static func groupIds(_ db: Database, classId: ClassID) throws -> [EquationGroupID] {
        try EquationGroupID.fetchAll(
            db, sql: "SELECT id FROM equation_groups WHERE classId = ? ORDER BY position, createdAt, id", arguments: [classId]
        )
    }

    private static func entryIds(_ db: Database, groupId: EquationGroupID) throws -> [EquationEntryID] {
        try EquationEntryID.fetchAll(
            db, sql: "SELECT id FROM equation_entries WHERE groupId = ? ORDER BY position, createdAt, id", arguments: [groupId]
        )
    }

    private static func renumberGroups(_ db: Database, classId: ClassID) throws {
        try writePositions(db, table: "equation_groups", ids: groupIds(db, classId: classId).map(\.raw))
    }

    private static func renumberEntries(_ db: Database, groupId: EquationGroupID) throws {
        try writePositions(db, table: "equation_entries", ids: entryIds(db, groupId: groupId).map(\.raw))
    }

    /// `ids[i].position = i`. `table` is one of the two sheet tables (never user input).
    private static func writePositions(_ db: Database, table: String, ids: [String]) throws {
        for (index, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE \(table) SET position = ? WHERE id = ?", arguments: [index, id])
        }
    }
}
