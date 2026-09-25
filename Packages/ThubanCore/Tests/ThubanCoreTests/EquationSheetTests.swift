import Foundation
import GRDB
import XCTest
@testable import ThubanCore

final class EquationSheetTests: XCTestCase {

    private func makeStore() throws -> Store {
        let locations = try StoreLocations.temporary(inMemoryDatabase: true)
        let store = try Store.open(locations)
        addTeardownBlock { try? FileManager.default.removeItem(at: locations.documents.deletingLastPathComponent()) }
        return store
    }

    private func makeClass(_ store: Store, name: String = "Multivariable Calculus") async throws -> ClassID {
        let studyClass = StudyClass(name: name)
        try await store.insert(studyClass)
        return studyClass.id
    }

    private func names(_ sheet: EquationSheet) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: sheet.sections.map { ($0.group.name, $0.entries.map(\.name)) })
    }

    // MARK: CRUD

    func testGroupsAndEntriesRoundTripInOrder() async throws {
        let store = try makeStore()
        let classId = try await makeClass(store)

        let empty = try await store.equationSheet(for: classId)
        XCTAssertTrue(empty.isEmpty)

        let derivatives = try await store.addEquationGroup(named: "Derivatives", to: classId)
        let series = try await store.addEquationGroup(named: "Series tests", to: classId)
        XCTAssertEqual(derivatives.position, 0)
        XCTAssertEqual(series.position, 1)

        let chain = try await store.addEquationEntry(
            EquationEntry(groupId: derivatives.id, name: "Chain rule", equations: ["\\frac{\\mathrm{d}}{\\mathrm{d}x}f(g(x)) = f'(g(x))g'(x)"]),
            at: nil
        )
        let product = try await store.addEquationEntry(
            EquationEntry(groupId: derivatives.id, name: "Product rule", equations: ["(fg)' = f'g + fg'"]), at: nil
        )
        // Inserted at the front.
        let power = try await store.addEquationEntry(
            EquationEntry(groupId: derivatives.id, name: "Power rule", equations: ["(x^n)' = nx^{n-1}"]), at: 0
        )
        let geometric = try await store.addEquationEntry(
            EquationEntry(groupId: series.id, name: "Geometric series",
                          equations: ["\\sum_{n=0}^{\\infty} ar^n = \\frac{a}{1-r}", "\\sum_{n=1}^{\\infty} ar^{n-1} = \\frac{a}{1-r}"],
                          note: "for |r| < 1"),
            at: nil
        )
        XCTAssertEqual(power.position, 0)
        XCTAssertTrue(geometric.isList)

        let sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.groups.map(\.name), ["Derivatives", "Series tests"])
        XCTAssertEqual(sheet.sections[0].entries.map(\.id), [power.id, chain.id, product.id])
        XCTAssertEqual(sheet.sections[0].entries.map(\.position), [0, 1, 2])
        let storedGeometric = try XCTUnwrap(sheet.entry(geometric.id))
        XCTAssertEqual(storedGeometric.equations.count, 2)
        XCTAssertEqual(storedGeometric.equations[0], "\\sum_{n=0}^{\\infty} ar^n = \\frac{a}{1-r}")
        XCTAssertEqual(storedGeometric.note, "for |r| < 1")
        XCTAssertEqual(sheet.entryCount, 4)

        // Rename, edit, delete.
        try await store.renameEquationGroup(series.id, to: "Series")
        var edited = chain
        edited.name = "Chain rule (one variable)"
        edited.equations = ["(f \\circ g)' = (f' \\circ g) \\cdot g'", "\\frac{\\mathrm{d}y}{\\mathrm{d}x} = \\frac{\\mathrm{d}y}{\\mathrm{d}u}\\frac{\\mathrm{d}u}{\\mathrm{d}x}"]
        edited.note = nil
        try await store.updateEquationEntry(edited)
        try await store.deleteEquationEntry(product.id)

        let after = try await store.equationSheet(for: classId)
        XCTAssertEqual(after.groups.map(\.name), ["Derivatives", "Series"])
        XCTAssertEqual(after.sections[0].entries.map(\.name), ["Power rule", "Chain rule (one variable)"])
        XCTAssertEqual(after.sections[0].entries.map(\.position), [0, 1])
        XCTAssertEqual(after.entry(chain.id)?.equations.count, 2)
        XCTAssertNil(after.entry(chain.id)?.note)

        // Deleting a group takes its entries along.
        try await store.deleteEquationGroup(derivatives.id)
        let remaining = try await store.equationSheet(for: classId)
        XCTAssertEqual(remaining.groups.map(\.name), ["Series"])
        XCTAssertEqual(remaining.groups.map(\.position), [0])
        let orphanCount = try await store.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM equation_entries WHERE groupId = ?", arguments: [derivatives.id]) ?? -1
        }
        XCTAssertEqual(orphanCount, 0)
    }

    func testUpdatingOrRenamingMissingRowsThrows() async throws {
        let store = try makeStore()
        let classId = try await makeClass(store)
        let group = try await store.addEquationGroup(named: "Vectors", to: classId)
        do {
            try await store.renameEquationGroup(EquationGroupID.new(), to: "x")
            XCTFail("expected a store error")
        } catch let error as ThubanError {
            guard case .store = error else { return XCTFail("unexpected \(error)") }
        }
        do {
            try await store.updateEquationEntry(EquationEntry(groupId: group.id, name: "Ghost", equations: ["x"]))
            XCTFail("expected a store error")
        } catch let error as ThubanError {
            guard case .store = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: Ordering

    func testMovingGroupsAndEntries() async throws {
        let store = try makeStore()
        let classId = try await makeClass(store)
        let a = try await store.addEquationGroup(named: "A", to: classId)
        let b = try await store.addEquationGroup(named: "B", to: classId)
        let c = try await store.addEquationGroup(named: "C", to: classId)

        try await store.moveEquationGroup(c.id, to: 0)
        var sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.groups.map(\.name), ["C", "A", "B"])
        try await store.moveEquationGroup(c.id, to: 99)   // clamped to the end
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.groups.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(sheet.groups.map(\.position), [0, 1, 2])

        var ids: [String: EquationEntryID] = [:]
        for name in ["a1", "a2", "a3"] {
            ids[name] = try await store.addEquationEntry(EquationEntry(groupId: a.id, name: name, equations: ["x"]), at: nil).id
        }
        ids["b1"] = try await store.addEquationEntry(EquationEntry(groupId: b.id, name: "b1", equations: ["y"]), at: nil).id

        // Within a group.
        try await store.moveEquationEntry(try XCTUnwrap(ids["a3"]), to: a.id, index: 0)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["a3", "a1", "a2"])

        // To another group, in the middle.
        try await store.moveEquationEntry(try XCTUnwrap(ids["a1"]), to: b.id, index: 0)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["a3", "a2"])
        XCTAssertEqual(names(sheet)["B"], ["a1", "b1"])
        XCTAssertEqual(sheet.sections[0].entries.map(\.position), [0, 1])
        XCTAssertEqual(sheet.sections[1].entries.map(\.position), [0, 1])

        // Changing the group through an update appends to the new group.
        var moved = try XCTUnwrap(sheet.entry(try XCTUnwrap(ids["a3"])))
        moved.groupId = c.id
        try await store.updateEquationEntry(moved)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["a2"])
        XCTAssertEqual(names(sheet)["C"], ["a3"])
        XCTAssertEqual(sheet.sections[0].entries.map(\.position), [0])

        // Deleting renumbers what is left.
        try await store.deleteEquationEntry(try XCTUnwrap(ids["a1"]))
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.sections[1].entries.map(\.position), [0])
    }

    func testPlacementAndRelativeMoves() async throws {
        let store = try makeStore()
        let classId = try await makeClass(store)
        let a = try await store.addEquationGroup(named: "A", to: classId)
        let b = try await store.addEquationGroup(named: "B", to: classId)
        let c = try await store.addEquationGroup(named: "C", to: classId)
        var ids: [String: EquationEntryID] = [:]
        for name in ["A", "B", "C", "D"] {
            ids[name] = try await store.addEquationEntry(EquationEntry(groupId: a.id, name: name, equations: ["x"]), at: nil).id
        }
        let x = try await store.addEquationEntry(EquationEntry(groupId: b.id, name: "X", equations: ["y"]), at: nil)
        let id = { (name: String) in try XCTUnwrap(ids[name]) }

        // A search shows only A and D; X dropped after D lands at the end of the full list, not between B and C.
        try await store.moveEquationEntry(x.id, to: a.id, placement: .after(try id("D")))
        var sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["A", "B", "C", "D", "X"])
        try await store.moveEquationEntry(x.id, to: a.id, placement: .before(try id("B")))
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["A", "X", "B", "C", "D"])
        try await store.moveEquationEntry(x.id, to: b.id, placement: .end)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["A", "B", "C", "D"])
        XCTAssertEqual(names(sheet)["B"], ["X"])
        XCTAssertEqual(sheet.sections[0].entries.map(\.position), [0, 1, 2, 3])

        // Relative moves read the stored position each time, so two quick steps move two places.
        try await store.moveEquationEntry(try id("A"), by: 1)
        try await store.moveEquationEntry(try id("A"), by: 1)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["B", "C", "A", "D"])
        try await store.moveEquationEntry(try id("A"), by: 9)   // clamped
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(names(sheet)["A"], ["B", "C", "D", "A"])

        try await store.moveEquationGroup(a.id, by: 1)
        try await store.moveEquationGroup(a.id, by: 1)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.groups.map(\.name), ["B", "C", "A"])
        try await store.moveEquationGroup(c.id, by: -5)
        sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.groups.map(\.name), ["C", "B", "A"])
        XCTAssertEqual(sheet.groups.map(\.position), [0, 1, 2])
    }

    func testEntriesCannotMoveToAnotherClass() async throws {
        let store = try makeStore()
        let first = try await makeClass(store, name: "One")
        let second = try await makeClass(store, name: "Two")
        let g1 = try await store.addEquationGroup(named: "G", to: first)
        let g2 = try await store.addEquationGroup(named: "G", to: second)
        let entry = try await store.addEquationEntry(EquationEntry(groupId: g1.id, name: "E", equations: ["x"]), at: nil)
        do {
            try await store.moveEquationEntry(entry.id, to: g2.id, index: 0)
            XCTFail("expected a store error")
        } catch is ThubanError {}
        let sheet = try await store.equationSheet(for: first)
        XCTAssertEqual(sheet.entryCount, 1)
        let otherSheet = try await store.equationSheet(for: second)
        XCTAssertEqual(otherSheet.entryCount, 0)
    }

    // MARK: Cascade

    func testDeletingAClassDeletesItsSheetOnly() async throws {
        let store = try makeStore()
        let keep = try await makeClass(store, name: "Keep")
        let drop = try await makeClass(store, name: "Drop")
        for classId in [keep, drop] {
            let group = try await store.addEquationGroup(named: "Vectors", to: classId)
            try await store.addEquationEntry(EquationEntry(groupId: group.id, name: "Dot product", equations: ["\\vec a\\cdot\\vec b"]), at: nil)
        }
        try await store.delete(drop, deleteFiles: false)

        let (groups, entries) = try await store.queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM equation_groups") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM equation_entries") ?? -1)
        }
        XCTAssertEqual(groups, 1)
        XCTAssertEqual(entries, 1)
        let kept = try await store.equationSheet(for: keep)
        XCTAssertEqual(kept.entryCount, 1)
        let dropped = try await store.equationSheet(for: drop)
        XCTAssertTrue(dropped.isEmpty)
    }

    // MARK: Migration

    /// A database created before equation sheets existed (every migration up to v5) upgrades in place: its data
    /// survives and the new tables work.
    func testMigrationAddsSheetsToAnExistingDatabase() async throws {
        let locations = try StoreLocations.temporary()
        addTeardownBlock { try? FileManager.default.removeItem(at: locations.documents.deletingLastPathComponent()) }
        let path = try XCTUnwrap(locations.database).path
        try FileManager.default.createDirectory(at: try XCTUnwrap(locations.database).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let classId = ClassID.new()
        do {
            let old = try DatabaseQueue(path: path)
            try Store.migrator.migrate(old, upTo: "v5-message-seed")
            try await old.write { db in
                try db.execute(sql: """
                    INSERT INTO classes (id, name, tutorStyle, sortOrder, createdAt) VALUES (?, 'Old class', 'socratic', 0, ?)
                    """, arguments: [classId, Date()])
            }
            let tables = try await old.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            }
            XCTAssertFalse(tables.contains("equation_groups"))
            try old.close()
        }

        let store = try Store.open(locations)
        let applied = try await store.queue.read { db in try Store.migrator.appliedIdentifiers(db) }
        XCTAssertTrue(applied.contains("v6-equation-sheets"))
        let classes = try await store.allClasses()
        XCTAssertEqual(classes.map(\.name), ["Old class"])

        let group = try await store.addEquationGroup(named: "Tangent planes", to: classId)
        try await store.addEquationEntry(EquationEntry(groupId: group.id, name: "Tangent plane",
                                                       equations: ["z - z_0 = f_x(x - x_0) + f_y(y - y_0)"]), at: nil)
        let sheet = try await store.equationSheet(for: classId)
        XCTAssertEqual(sheet.entryCount, 1)

        // Foreign keys hold on the upgraded file too.
        try await store.delete(classId, deleteFiles: false)
        let left = try await store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM equation_entries") ?? -1 }
        XCTAssertEqual(left, 0)
        try store.close()
    }

    // MARK: Search

    func testFilteringMatchesNameNoteLatexAndGroup() {
        let classId = ClassID.new()
        let g1 = EquationGroup(classId: classId, name: "Derivatives")
        let g2 = EquationGroup(classId: classId, name: "Series tests")
        let sheet = EquationSheet(classId: classId, sections: [
            .init(group: g1, entries: [
                EquationEntry(groupId: g1.id, name: "Chain rule", equations: ["(f\\circ g)' = f'(g)\\,g'"]),
                EquationEntry(groupId: g1.id, name: "Quotient rule", equations: ["\\left(\\frac{f}{g}\\right)' = \\frac{f'g - fg'}{g^2}"]),
            ]),
            .init(group: g2, entries: [
                EquationEntry(groupId: g2.id, name: "Geometric series", equations: ["\\sum ar^n = \\frac{a}{1-r}"], note: "for |r| < 1"),
                EquationEntry(groupId: g2.id, name: "Ratio test", equations: ["L = \\lim_{n\\to\\infty}\\left|\\frac{a_{n+1}}{a_n}\\right|"]),
            ]),
        ])

        XCTAssertEqual(sheet.filtered(by: "  "), sheet)
        XCTAssertEqual(sheet.filtered(by: "CHAIN").sections.flatMap { $0.entries.map(\.name) }, ["Chain rule"])
        XCTAssertEqual(sheet.filtered(by: "|r|").sections.flatMap { $0.entries.map(\.name) }, ["Geometric series"])
        // LaTeX, typed with or without the backslash.
        XCTAssertEqual(sheet.filtered(by: "\\frac").sections.flatMap { $0.entries.map(\.name) },
                       ["Quotient rule", "Geometric series", "Ratio test"])
        XCTAssertEqual(sheet.filtered(by: "lim").sections.flatMap { $0.entries.map(\.name) }, ["Ratio test"])
        XCTAssertEqual(sheet.filtered(by: "\\lim_{n").sections.flatMap { $0.entries.map(\.name) }, ["Ratio test"])
        // Every word must match; a matching group keeps all of its entries.
        XCTAssertEqual(sheet.filtered(by: "rule quotient").sections.flatMap { $0.entries.map(\.name) }, ["Quotient rule"])
        XCTAssertEqual(sheet.filtered(by: "series tests").sections.first?.entries.count, 2)
        XCTAssertTrue(sheet.filtered(by: "laplace").isEmpty)
    }

    func testCleanedEquationsDropBlanks() {
        XCTAssertEqual(EquationEntry.cleaned(["  x^2 ", "", "   ", "y"]), ["x^2", "y"])
    }
}
