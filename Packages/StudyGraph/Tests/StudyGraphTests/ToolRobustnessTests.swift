import Foundation
import GraphModel
import GraphTypes
@testable import StudyGraph
import ThubanCore
import XCTest

/// Regression tests for the engine-switch review: the load race, tutor ownership through undo, ids across modes,
/// Reset view and equal axes, stale warnings, point sequences and non-destructive loading.
@MainActor
final class ToolRobustnessTests: XCTestCase {
    private func run(_ name: String, _ input: JSONValue = [:], _ host: StudyGraphHost) async -> JSONValue {
        await StudyGraphTools.execute(name: name, arguments: input, host: host, mayEditGraph: true) ?? .null
    }

    /// The kit reports view-driven changes (undo in the list) asynchronously, through Observation.
    private func settle() async throws {
        for _ in 0 ..< 5 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A class whose saved graph holds the tutor row `old`.
    private func savedClass() async throws -> (Store, ClassID) {
        let store = try Store.inMemory()
        let classId = ClassID.new()
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        _ = await run(TutorTools.graphAddExpression, ["id": "old", "latex": "y=x"], host)
        await host.saveNow()
        return (store, classId)
    }

    // MARK: Load race

    /// ClassSession.graphHost: the host is created and connected, and the tutor's first call follows at once.
    func testToolCallRightAfterConnectKeepsItsEditAndTheSavedRows() async throws {
        let (store, classId) = try await savedClass()
        let host = StudyGraphHost(engine: nil)
        host.connect(store: store, classId: classId)
        XCTAssertFalse(host.isLoaded, "the list stays hidden until the saved graph is in")
        let reply = await run(TutorTools.graphAddExpression, ["id": "new", "latex": "y=2"], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 2])
        XCTAssertTrue(host.isLoaded)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.rows.map(\.id), ["old", "new"])
        XCTAssertEqual(host.tutorIDs, ["old", "new"])
        await host.saveNow()
        let stored = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self)
        XCTAssertEqual(stored?["tutorIDs"], ["new", "old"])

        let second = StudyGraphHost(engine: nil)
        second.connect(store: store, classId: classId)
        let removed = await run(TutorTools.graphRemoveExpression, ["id": "old"], second)
        XCTAssertEqual(removed, ["ok": true, "mode": "2d", "count": 1])
        XCTAssertEqual(second.rows.map(\.id), ["new"])
    }

    // MARK: Ownership through undo

    func testUndoingATutorClearOrRemoveKeepsTheRowsTheTutors() async throws {
        let host = StudyGraphHost(engine: nil)
        _ = await run(TutorTools.graphAddExpression, ["id": "t1", "latex": "y=x"], host)
        _ = await run(TutorTools.graphAddExpression, ["id": "t2", "latex": "x=2", "dashed": true], host)
        _ = await run(TutorTools.graphClear, [:], host)
        XCTAssertEqual(host.tutorIDs, [])
        host.twoD.session.undo()
        try await settle()
        XCTAssertEqual(host.twoD.document.item("t1")?.color, .teal)
        XCTAssertEqual(host.twoD.document.item("t2")?.color, .teal)
        XCTAssertEqual(host.tutorIDs, ["t1", "t2"])
        XCTAssertEqual(host.rows.filter(\.fromTutor).map(\.id), ["t1", "t2"])
        host.twoD.session.redo()
        try await settle()
        XCTAssertEqual(host.tutorIDs, [])
        host.twoD.session.undo()
        try await settle()
        XCTAssertEqual(host.tutorIDs, ["t1", "t2"])

        _ = await run(TutorTools.graphAddExpression, ["id": "t3", "latex": "y=3"], host)
        _ = await run(TutorTools.graphRemoveExpression, ["id": "t3"], host)
        host.twoD.session.undo()
        try await settle()
        XCTAssertEqual(host.twoD.document.item("t3")?.color, .teal)
        XCTAssertTrue(host.tutorIDs.contains("t3"))
    }

    func testARestoredStudentRowKeepsItsColorAndANewOneTakesTheAccent() async throws {
        let host = StudyGraphHost(engine: nil)
        var row = host.twoD.session.newItem(latex: "y=x")
        row.color = .violet
        host.twoD.session.perform(.addItem(row, after: nil))   // as the list does: reported as the user's
        try await settle()
        XCTAssertEqual(host.twoD.document.item(row.id)?.color, .brass, "a new student row takes the accent")
        host.twoD.session.perform(.setColor(row.id, .violet))   // the student picks violet
        host.twoD.session.perform(.deleteItem(row.id))
        try await settle()
        host.twoD.session.undo()
        try await settle()
        XCTAssertEqual(host.twoD.document.item(row.id)?.color, .violet, "undo restores the row as it was")
        XCTAssertFalse(host.tutorIDs.contains(row.id.rawValue))
    }

    // MARK: Ids across modes

    func testRemoveFindsTheRowInEitherModeAndAddMovesItBetweenModes() async throws {
        let host = StudyGraphHost(engine: nil)
        _ = await run(TutorTools.showGraph, ["mode": "3d"], host)
        _ = await run(TutorTools.graphAddExpression, ["id": "g", "latex": "z=1"], host)
        _ = await run(TutorTools.showGraph, ["mode": "2d"], host)
        let removed = await run(TutorTools.graphRemoveExpression, ["id": "g"], host)
        XCTAssertEqual(removed, ["ok": true, "mode": "2d", "count": 0])
        XCTAssertNil(host.threeD.document.item("g"))
        XCTAssertEqual(host.tutorIDs, [])

        _ = await run(TutorTools.graphAddExpression, ["id": "f", "latex": "y=x^2", "dashed": true], host)
        _ = await run(TutorTools.showGraph, ["mode": "3d"], host)
        let moved = await run(TutorTools.graphAddExpression, ["id": "f", "latex": "z=x^2"], host)
        XCTAssertEqual(moved, ["ok": true, "mode": "3d", "count": 1])
        XCTAssertNil(host.twoD.document.item("f"), "one row per id across both modes")
        XCTAssertEqual(host.threeD.document.item("f")?.latex, "z=x^2")
        XCTAssertEqual(host.tutorIDs, ["f"])
        XCTAssertEqual(host.rows.map(\.id), ["f"])
    }

    func testIdsAreTrimmedTheSameWayOnAddAndRemove() async {
        let host = StudyGraphHost(engine: nil)
        _ = await run(TutorTools.graphAddExpression, ["id": " h ", "latex": "y=1"], host)
        XCTAssertNotNil(host.twoD.document.item("h"))
        let reply = await run(TutorTools.graphRemoveExpression, ["id": " h "], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 0])
        let blank = await run(TutorTools.graphRemoveExpression, ["id": "  "], host)
        XCTAssertEqual(blank, ["error": "id is required."])
    }

    // MARK: Viewport

    func testResetViewBringsBackEqualAxesAndItIsSaved() async throws {
        let store = try Store.inMemory()
        let classId = ClassID.new()
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        XCTAssertTrue(host.twoD.document.settings.equalAxes)
        _ = await run(TutorTools.graphSetViewport, ["xmin": -1, "xmax": 1, "ymin": -100, "ymax": 100], host)
        XCTAssertFalse(host.twoD.document.settings.equalAxes)
        host.resetView()
        XCTAssertTrue(host.twoD.document.settings.equalAxes)
        XCTAssertEqual(host.twoD.document.viewport, Viewport2D.standard)
        host.twoD.session.undo()
        XCTAssertFalse(host.twoD.document.settings.equalAxes, "reset is one undo step")
        host.twoD.session.redo()
        await host.saveNow()
        let reopened = StudyGraphHost(engine: nil)
        await reopened.attach(store: store, classId: classId)
        XCTAssertTrue(reopened.twoD.document.settings.equalAxes)
    }

    // MARK: Point sequences

    func testATopLevelRunOfPointsBecomesAPointList() {
        XCTAssertEqual(StudyGraphTools.normalizedLatex("(2,3),(4,5)"), "\\left[(2,3),(4,5)\\right]")
        XCTAssertEqual(StudyGraphTools.normalizedLatex("(1,2),(3,4),(5,6)"), "\\left[(1,2),(3,4),(5,6)\\right]")
        XCTAssertEqual(StudyGraphTools.normalizedLatex("\\left(1,2\\right),\\left(3,4\\right)"),
                       "\\left[\\left(1,2\\right),\\left(3,4\\right)\\right]")
        XCTAssertEqual(StudyGraphTools.normalizedLatex("(1,2,3),(4,5,6)"), "\\left[(1,2,3),(4,5,6)\\right]")
        for kept in ["(1,2)", "\\left[(1,2),(3,4)\\right]", "y=x", "f(x)=x", "(1)+(2),(3,4)", "A=(1,2),(3,4)",
                     "(\\frac{1}{2},3),(4,5)x", "\\left(0,-0.25\\right)"] {
            XCTAssertEqual(StudyGraphTools.normalizedLatex(kept), kept, kept)
        }
        XCTAssertEqual(StudyGraphTools.normalizedLatex("(\\frac{1}{2},3),(4,\\sqrt{5})"),
                       "\\left[(\\frac{1}{2},3),(4,\\sqrt{5})\\right]")
    }

    // MARK: Real engine

    func testPointRunsDrawAndStaleWarningsAreNotReported() async throws {
        let engine = StudyGraphEngine()
        await engine.waitUntilWarm()
        XCTAssertNil(engine.startupError)
        let host = StudyGraphHost(engine: engine)
        StudyGraphTools.warningTimeout = .seconds(20)
        defer { StudyGraphTools.warningTimeout = .milliseconds(1500) }

        for (id, latex) in [("pts", "(2,3),(4,5)"), ("pts3", "(1,2),(3,4),(5,6)")] {
            let reply = await run(TutorTools.graphAddExpression, ["id": .string(id), "latex": .string(latex)], host)
            XCTAssertNil(reply["warnings"], "\(latex): \(reply)")
            XCTAssertNil(reply["analysisPending"])
        }

        let broken = await run(TutorTools.graphAddExpression, ["id": "f", "latex": "y=\\frac{1}{"], host)
        XCTAssertEqual(broken["warnings"]?.arrayValue?.count, 1, "\(broken)")
        // The fix arrives with no time to analyse it: the old error must not be reported against it.
        StudyGraphTools.warningTimeout = .milliseconds(1)
        let fixed = await run(TutorTools.graphAddExpression, ["id": "f", "latex": "y=\\frac{1}{x}"], host)
        XCTAssertNil(fixed["warnings"], "\(fixed)")
        XCTAssertEqual(fixed["analysisPending"], true)
        StudyGraphTools.warningTimeout = .seconds(20)
        let settled = await run(TutorTools.graphAddExpression, ["id": "f", "latex": "y=\\frac{1}{x}"], host)
        XCTAssertNil(settled["warnings"], "\(settled)")
        XCTAssertNil(settled["analysisPending"])
    }

    // MARK: Non-destructive load

    func testARecordFromANewerStudyIsNeverOverwritten() async throws {
        let store = try Store.inMemory()
        let classId = ClassID.new()
        let newer: JSONValue = ["format": "thuban-study-graph", "version": 2, "twoD": ["precious": "data"]]
        try await store.set(StudyGraphRecord.key(for: classId), newer)
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        XCTAssertTrue(host.isLoaded)
        _ = await run(TutorTools.graphAddExpression, ["id": "t", "latex": "y=1"], host)
        XCTAssertNotNil(host.twoD.document.item("t"), "edits still work in memory")
        await host.saveNow()
        try await Task.sleep(for: .milliseconds(500))
        let stored = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self)
        XCTAssertEqual(stored, newer)
    }

    func testAnUnreadableRowIsCopiedAsideBeforeItIsReplaced() async throws {
        let store = try Store.inMemory()
        let classId = ClassID.new()
        let garbage: JSONValue = ["format": "something-else", "keep": "me"]
        try await store.set(StudyGraphRecord.key(for: classId), garbage)
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        XCTAssertEqual(host.rows, [])
        let backup = try await store.get(StudyGraphRecord.backupKey(for: classId), as: JSONValue.self)
        XCTAssertEqual(backup, garbage)
        _ = await run(TutorTools.graphAddExpression, ["id": "t", "latex": "y=1"], host)
        await host.saveNow()
        let stored = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self)
        XCTAssertEqual(stored?["tutorIDs"], ["t"])

        await StudyGraphHost.deleteSavedGraph(store: store, classId: classId)
        let afterDelete = try await store.get(StudyGraphRecord.backupKey(for: classId), as: JSONValue.self)
        XCTAssertNil(afterDelete)
    }
}
