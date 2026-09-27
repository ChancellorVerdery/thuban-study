import Foundation
import GraphModel
import GraphTypes
@testable import StudyGraph
import ThubanCore
import XCTest

/// The tutor's graph tools replayed against a headless host (STUDY_INTEGRATION.md §10 "Tool replay"); one case
/// runs on the real Graph engine for the `warnings` field.
@MainActor
final class StudyGraphToolsTests: XCTestCase {
    private func run(_ name: String, _ input: JSONValue = [:], _ host: StudyGraphHost, mayEdit: Bool = true) async -> JSONValue {
        let reply = await StudyGraphTools.execute(name: name, arguments: input, host: host, mayEditGraph: mayEdit)
        XCTAssertNotNil(reply, "\(name) is a graph tool")
        return reply ?? .null
    }

    private func item(_ host: StudyGraphHost, _ mode: StudyGraphMode, _ id: String) -> ExpressionItem? {
        host.session(mode).document.item(ExpressionID(id))
    }

    func testReplayScript() async throws {
        let host = StudyGraphHost(engine: nil)
        var shown: [Bool] = []
        var modes: [StudyGraphMode] = []
        host.onShowGraph = { shown.append($0) }
        host.onModeChange = { modes.append($0) }

        // 1. show_graph 2d
        var reply = await run(TutorTools.showGraph, ["mode": "2d"], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 0])
        XCTAssertEqual(shown, [true])
        XCTAssertTrue(host.tutorEditedRecently)

        // 2. the Study smoke rows (a user rational function, dashed asymptotes, a labelled line, a point)
        // The student types into the blank row.
        let userID = try XCTUnwrap(host.twoD.document.items.first?.id)
        host.twoD.perform(.setLatex(userID, "f(x)=\\frac{2x^2+1}{x^2-4}"), origin: .user)
        let rows: [JSONValue] = [
            ["id": "va1", "latex": "x=-2", "dashed": true],
            ["id": "va2", "latex": "x=2", "dashed": true],
            ["id": "ha", "latex": "y=2", "label": "y=2"],
            ["id": "pt", "latex": "\\left(0,-0.25\\right)", "color": "#C74440"],
        ]
        for (index, row) in rows.enumerated() {
            reply = await run(TutorTools.graphAddExpression, row, host)
            XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": .number(Double(index + 2))], "row \(index)")
        }
        XCTAssertEqual(item(host, .twoD, "va1")?.color, .teal)
        XCTAssertEqual(item(host, .twoD, "va1")?.style.lineDash, .dashed)
        XCTAssertEqual(item(host, .twoD, "ha")?.style.lineDash, .solid)
        XCTAssertEqual(item(host, .twoD, "ha")?.style.labelLatex, "y=2")
        XCTAssertEqual(item(host, .twoD, "ha")?.style.showLabel, true)
        XCTAssertEqual(item(host, .twoD, "pt")?.color, .custom("#c74440"))
        XCTAssertEqual(host.tutorIDs, ["va1", "va2", "ha", "pt"])
        XCTAssertEqual(host.rows.filter(\.fromTutor).map(\.id), ["va1", "va2", "ha", "pt"])
        XCTAssertEqual(host.rows.first { $0.id == userID.rawValue }?.fromTutor, false)
        XCTAssertEqual(host.twoD.document.items.map(\.id.rawValue), [userID.rawValue, "va1", "va2", "ha", "pt"])

        // 3. upsert the same id: one undo step, count unchanged
        reply = await run(TutorTools.graphAddExpression, ["id": "va2", "latex": "x=3", "dashed": true], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 5])
        XCTAssertEqual(item(host, .twoD, "va2")?.latex, "x=3")
        host.twoD.session.undo()
        XCTAssertEqual(item(host, .twoD, "va2")?.latex, "x=2")
        host.twoD.session.redo()

        // 4. remove an unknown id
        reply = await run(TutorTools.graphRemoveExpression, ["id": "nope"], host)
        XCTAssertEqual(reply, ["error": "No expression with id 'nope'."])
        reply = await run(TutorTools.graphRemoveExpression, ["id": "pt"], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 4])
        XCTAssertFalse(host.tutorIDs.contains("pt"))

        // 5. viewport: refused in 3D, exact in 2D
        reply = await run(TutorTools.showGraph, ["mode": "3d"], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "3d", "count": 0])
        XCTAssertEqual(modes, [.threeD])
        reply = await run(TutorTools.graphAddExpression, ["id": "s1", "latex": "z=x^2-y^2"], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "3d", "count": 1])
        XCTAssertNotNil(item(host, .threeD, "s1"))
        XCTAssertNil(item(host, .twoD, "s1"))
        reply = await run(TutorTools.graphSetViewport, ["xmin": -5, "xmax": 5, "ymin": -3, "ymax": 3], host)
        XCTAssertEqual(reply, ["error": "The viewport can only be set in 2D mode; the graph is in 3D."])
        reply = await run(TutorTools.showGraph, ["mode": "2d"], host)
        reply = await run(TutorTools.graphSetViewport, ["xmin": -5, "xmax": 5, "ymin": -3, "ymax": 3], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 4])
        XCTAssertEqual(host.twoD.document.viewport, Viewport2D(xMin: -5, xMax: 5, yMin: -3, yMax: 3))
        XCTAssertFalse(host.twoD.document.settings.equalAxes)
        reply = await run(TutorTools.graphSetViewport, ["xmin": 5, "xmax": -5, "ymin": -3, "ymax": 3], host)
        XCTAssertEqual(reply, ["error": "xmin < xmax and ymin < ymax are required."])

        // 6. graph_clear clears the mode on screen only (viewport kept, undoable)
        reply = await run(TutorTools.graphClear, [:], host)
        XCTAssertEqual(reply, ["ok": true, "mode": "2d", "count": 0])
        XCTAssertEqual(host.twoD.document.viewport, Viewport2D(xMin: -5, xMax: 5, yMin: -3, yMax: 3))
        XCTAssertNotNil(item(host, .threeD, "s1"), "the 3D rows survive a 2D clear")
        XCTAssertEqual(host.tutorIDs, ["s1"])
        host.twoD.session.undo()
        XCTAssertEqual(host.rowCount(.twoD), 4)

        // hide_graph
        reply = await run(TutorTools.hideGraph, [:], host)
        XCTAssertEqual(reply, ["ok": true])
        XCTAssertEqual(shown.last, false)

        // 7. gating: editing tools refused, show/hide still work
        for name in TutorTools.graphEditingTools {
            reply = await run(name, ["id": "va1", "latex": "x=1", "xmin": 0, "xmax": 1, "ymin": 0, "ymax": 1], host, mayEdit: false)
            XCTAssertEqual(reply, ["error": "The student has disabled tutor graph edits."], name)
        }
        reply = await run(TutorTools.showGraph, ["mode": "2d"], host, mayEdit: false)
        XCTAssertEqual(reply["ok"], true)

        // Non-graph tools are left to the class session.
        let other = await StudyGraphTools.execute(name: TutorTools.getStudentWork, arguments: [:], host: host, mayEditGraph: true)
        XCTAssertNil(other)
        XCTAssertEqual(StudyGraphTools.names.count, 6)
    }

    func testAddRequiresIdAndLatex() async {
        let host = StudyGraphHost(engine: nil)
        let reply = await run(TutorTools.graphAddExpression, ["id": "a"], host)
        XCTAssertEqual(reply, ["error": "id and latex are required."])
    }

    func testTutorRowIntoEmptyGraphGoesAboveTheBlankRow() async {
        let host = StudyGraphHost(engine: nil)
        XCTAssertEqual(host.twoD.document.items.count, 1)
        _ = await run(TutorTools.graphAddExpression, ["id": "f", "latex": "y=x^2"], host)
        XCTAssertEqual(host.twoD.document.items.first?.id, "f")
        XCTAssertEqual(host.twoD.document.items.count, 2)
        XCTAssertTrue(host.twoD.document.items[1].latex.isEmpty)
    }

    func testColorNames() {
        XCTAssertEqual(StudyGraphTools.seriesColor(named: "teal"), .teal)
        XCTAssertEqual(StudyGraphTools.seriesColor(named: "RED"), .rust)
        XCTAssertEqual(StudyGraphTools.seriesColor(named: "purple"), .violet)
        XCTAssertEqual(StudyGraphTools.seriesColor(named: "#2D70B3"), .custom("#2d70b3"))
        XCTAssertEqual(StudyGraphTools.seriesColor(named: "#abc"), .custom("#aabbcc"))
        XCTAssertNil(StudyGraphTools.seriesColor(named: "#zzzzzz"))
        XCTAssertNil(StudyGraphTools.seriesColor(named: "chartreuse-ish"))
    }

    func testUserRowsTakeTheAccent() async throws {
        let host = StudyGraphHost(engine: nil)
        _ = await run(TutorTools.graphAddExpression, ["id": "t", "latex": "y=1"], host)
        // The list adds rows with the next automatic series color (here teal); the host recolors user rows to brass.
        let row = host.twoD.session.newItem(latex: "y=x")
        XCTAssertNotEqual(row.color, .brass)
        host.twoD.perform(.addItem(row, after: nil), origin: .user)
        XCTAssertEqual(host.twoD.document.item(row.id)?.color, .brass)
        XCTAssertEqual(host.twoD.document.item("t")?.color, .teal)
    }

    /// The real engine: rows Desmos accepted analyse cleanly, a broken row comes back as a warning.
    func testWarningsFromTheRealEngine() async throws {
        let engine = StudyGraphEngine()
        await engine.waitUntilWarm()
        XCTAssertNil(engine.startupError)
        let host = StudyGraphHost(engine: engine)
        StudyGraphTools.warningTimeout = .seconds(20)
        defer { StudyGraphTools.warningTimeout = .milliseconds(1500) }
        let clean: [JSONValue] = [
            ["id": "f", "latex": "f(x)=\\frac{2x^2+1}{x^2-4}"],
            ["id": "va", "latex": "x=2", "dashed": true],
            ["id": "pt", "latex": "\\left(0,-0.25\\right)"],
            ["id": "c", "latex": "\\left(\\cos t,\\sin t\\right)"],
            ["id": "r", "latex": "y=x\\left\\{x>0\\right\\}"],
            ["id": "l", "latex": "\\left[1,2,3\\right]"],
        ]
        for row in clean {
            let reply = await run(TutorTools.graphAddExpression, row, host)
            XCTAssertNil(reply["warnings"], "\(row): \(reply)")
            XCTAssertEqual(reply["ok"], true)
        }
        let reply = await run(TutorTools.graphAddExpression, ["id": "bad", "latex": "y=\\frac{1}{"], host)
        let warnings = reply["warnings"]?.arrayValue ?? []
        XCTAssertEqual(warnings.compactMap { $0["id"]?.stringValue }, ["bad"], "\(reply)")
        XCTAssertFalse(warnings.first?["message"]?.stringValue?.isEmpty ?? true)
    }
}
