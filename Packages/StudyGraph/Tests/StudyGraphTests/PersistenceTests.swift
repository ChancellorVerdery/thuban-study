import Foundation
import GraphModel
import GraphTypes
@testable import StudyGraph
import ThubanCore
import XCTest

/// `classGraph.<class id>` round trip, the launch migration and the Desmos-era converters.
@MainActor
final class PersistenceTests: XCTestCase {
    private func makeStore() throws -> Store { try Store.inMemory() }

    func testRecordRoundTripKeepsBothModesAndTutorIDs() async throws {
        let store = try makeStore()
        let classId = ClassID.new()
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        _ = await StudyGraphTools.execute(name: TutorTools.graphAddExpression, arguments: ["id": "va", "latex": "x=2", "dashed": true],
                                          host: host, mayEditGraph: true)
        _ = await StudyGraphTools.execute(name: TutorTools.graphSetViewport, arguments: ["xmin": -4, "xmax": 4, "ymin": -2, "ymax": 6],
                                          host: host, mayEditGraph: true)
        host.mode = .threeD
        _ = await StudyGraphTools.execute(name: TutorTools.graphAddExpression, arguments: ["id": "s", "latex": "z=\\sin(x)\\cos(y)"],
                                          host: host, mayEditGraph: true)
        await host.saveNow()

        // Each half is a valid .thgraph document.
        let fetched = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self)
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(stored["format"], "thuban-study-graph")
        XCTAssertEqual(stored["version"], 1)
        XCTAssertEqual(stored["tutorIDs"], ["s", "va"])
        let twoD = try GraphFile.decode(try XCTUnwrap(stored["twoD"]).data())
        XCTAssertEqual(twoD.mode, .twoD)
        XCTAssertEqual(twoD.item("va")?.style.lineDash, .dashed)
        let threeD = try GraphFile.decode(try XCTUnwrap(stored["threeD"]).data())
        XCTAssertEqual(threeD.mode, .threeD)
        XCTAssertEqual(threeD.item("s")?.latex, "z=\\sin(x)\\cos(y)")

        // A new host for the same class (the next launch) reads it back.
        let reopened = StudyGraphHost(engine: nil)
        await reopened.attach(store: store, classId: classId)
        XCTAssertEqual(reopened.twoD.document, host.twoD.document)
        XCTAssertEqual(reopened.threeD.document.items, host.threeD.document.items)
        XCTAssertEqual(reopened.tutorIDs, ["va", "s"])
        XCTAssertEqual(reopened.twoD.document.viewport, Viewport2D(xMin: -4, xMax: 4, yMin: -2, yMax: 6))
        XCTAssertEqual(reopened.rows.filter(\.fromTutor).map(\.id).sorted(), ["s", "va"])
    }

    func testChangesAreSavedAfterTheDebounce() async throws {
        let store = try makeStore()
        let classId = ClassID.new()
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        _ = await StudyGraphTools.execute(name: TutorTools.graphAddExpression, arguments: ["id": "f", "latex": "y=x"], host: host, mayEditGraph: true)
        try await Task.sleep(for: .milliseconds(700))
        let stored = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self)
        withExtendedLifetime(host) {}   // the class session keeps its host; ARC would release this one early
        XCTAssertEqual(stored?["tutorIDs"], ["f"])
    }

    func testUnreadableRowFallsBackToEmptyGraphs() async throws {
        let store = try makeStore()
        let classId = ClassID.new()
        try await store.set(StudyGraphRecord.key(for: classId), JSONValue.object(["format": "something-else"]))
        let host = StudyGraphHost(engine: nil)
        await host.attach(store: store, classId: classId)
        XCTAssertEqual(host.rows, [])
        XCTAssertEqual(host.twoD.document.items.count, 1)
    }

    func testDeletingAClassRemovesItsGraph() async throws {
        let store = try makeStore()
        let classId = ClassID.new()
        try await store.set(StudyGraphRecord.key(for: classId), JSONValue.object(["format": "thuban-study-graph"]))
        await StudyGraphHost.deleteSavedGraph(store: store, classId: classId)
        let stored = try await store.get(StudyGraphRecord.key(for: classId), as: JSONValue.self)
        XCTAssertNil(stored)
    }

    // MARK: Migration

    func testMigrationPurgesTheDesmosKeyOnceAndIsIdempotent() async throws {
        let store = try makeStore()
        try await store.set(SettingsKey("desmosKey"), "abc-123")
        try await store.set(.tutorMayEditGraph, false)
        let ran = try await StudyGraphMigration.run(store: store)
        XCTAssertTrue(ran)
        let key = try await store.get(SettingsKey("desmosKey"), as: String.self)
        XCTAssertNil(key)
        let kept = try await store.get(.tutorMayEditGraph, as: Bool.self)
        XCTAssertEqual(kept, false, "other settings are untouched")
        let marker = try await store.get(StudyGraphMigration.marker, as: Int.self)
        XCTAssertEqual(marker, 1)

        // A second launch does nothing (even if something wrote the old key again).
        try await store.set(SettingsKey("desmosKey"), "late")
        let again = try await StudyGraphMigration.run(store: store)
        XCTAssertFalse(again)
        let keys = try await store.settingsKeys().map(\.rawValue)
        XCTAssertEqual(keys, ["desmosKey", "migrations.graphKit", "tutorMayEditGraph"])
    }

    func testMigrationOnAFreshStore() async throws {
        let store = try makeStore()
        let ran = try await StudyGraphMigration.run(store: store)
        XCTAssertTrue(ran)
        let keys = try await store.settingsKeys().map(\.rawValue)
        XCTAssertEqual(keys, ["migrations.graphKit"])
    }

    // MARK: Converters

    func testLegacyRowFieldsConvert() throws {
        let theme = LegacyThemeColors(accent: "#B08D3E", signal: "#2F8F8A", accentDeep: "#7F6530")
        func convert(_ row: LegacyGraphExpression) -> GraphExpressionConverter.Converted {
            GraphExpressionConverter.convert(row, theme: theme)
        }
        // id, latex, default colors (user brass, tutor teal, dashed tutor teal + dashed)
        var converted = convert(LegacyGraphExpression(id: "f", latex: "y=x^2"))
        XCTAssertEqual(converted.item.id, "f")
        XCTAssertEqual(converted.item.latex, "y=x^2")
        XCTAssertEqual(converted.item.color, .brass)
        XCTAssertFalse(converted.fromTutor)
        converted = convert(LegacyGraphExpression(id: "t", latex: "x=2", dashed: true, fromTutor: true))
        XCTAssertEqual(converted.item.color, .teal)
        XCTAssertEqual(converted.item.style.lineDash, .dashed)
        XCTAssertTrue(converted.fromTutor)
        // theme hexes map back to series tokens; any other hex is custom
        XCTAssertEqual(convert(LegacyGraphExpression(id: "a", latex: "y=1", color: "#b08d3e")).item.color, .brass)
        XCTAssertEqual(convert(LegacyGraphExpression(id: "a", latex: "y=1", color: "#2F8F8A")).item.color, .teal)
        converted = convert(LegacyGraphExpression(id: "a", latex: "y=1", color: "#7f6530"))
        XCTAssertEqual(converted.item.color, .teal)
        XCTAssertEqual(converted.item.style.lineDash, .dashed)
        XCTAssertEqual(convert(LegacyGraphExpression(id: "a", latex: "y=1", color: "#C74440")).item.color, .custom("#c74440"))
        // dotted, label, hidden
        XCTAssertEqual(convert(LegacyGraphExpression(id: "d", latex: "y=1", dotted: true)).item.style.lineDash, .dotted)
        converted = convert(LegacyGraphExpression(id: "l", latex: "y=2", label: "y = 2", hidden: true))
        XCTAssertEqual(converted.item.style.labelLatex, "y = 2")
        XCTAssertTrue(converted.item.style.showLabel)
        XCTAssertTrue(converted.item.isHidden)
        // opacities, width, domain, slider bounds, mode, points
        var row = LegacyGraphExpression(id: "p", latex: "\\left(\\cos t,\\sin t\\right)", mode: "3d")
        row.fillOpacity = 0.25
        row.lineOpacity = 0.5
        row.lineWidth = 4
        row.parametricDomain = .init(min: 0, max: 6.28)
        row.showsPoints = true
        converted = convert(row)
        XCTAssertEqual(converted.item.style.fillOpacity, 0.25)
        XCTAssertEqual(converted.item.style.lineOpacity, 0.5)
        XCTAssertEqual(converted.item.style.lineWidth, 4)
        XCTAssertEqual(converted.item.domain, ParameterBounds(min: "0", max: "6.28"))
        XCTAssertEqual(converted.mode, .threeD)
        XCTAssertEqual(converted.skipped, 0)
        row = LegacyGraphExpression(id: "a", latex: "a=3", sliderBounds: .init(min: -5, max: 5, step: 0.5))
        converted = convert(row)
        XCTAssertEqual(converted.item.slider?.min, -5)
        XCTAssertEqual(converted.item.slider?.max, 5)
        XCTAssertEqual(converted.item.slider?.step, 0.5)
        XCTAssertEqual(converted.item.slider?.value, 3)
        // points: false has no equivalent and is counted, unknown payload keys too
        row = LegacyGraphExpression(id: "q", latex: "\\left[(1,2),(3,4)\\right]", showsPoints: false)
        XCTAssertEqual(convert(row).skipped, 1)
        let payload = GraphExpressionConverter.convert(payload: ["id": "z", "latex": "y=3", "weird": 1, "lineStyle": "SOLID"])
        XCTAssertEqual(payload.skipped, 1)
        XCTAssertEqual(payload.item.id, "z")
    }

    func testLegacyRowListDecodesLenientlyAndSplitsByMode() throws {
        let json = """
        [{"id":"f","latex":"y=x"},
         {"id":"t","latex":"x=1","fromTutor":true,"dashed":true},
         {"id":"s","latex":"z=x+y","mode":"3d","fromTutor":true}]
        """
        let contents = try StudyGraphRecord.decode(try JSONValue(jsonString: json))
        XCTAssertEqual(contents.twoD.items.map(\.id.rawValue), ["f", "t"])
        XCTAssertEqual(contents.threeD.items.map(\.id.rawValue), ["s"])
        XCTAssertEqual(contents.threeD.mode, .threeD)
        XCTAssertEqual(contents.tutorIDs, ["t", "s"])
    }

    func testFullDesmosStatesConvert() throws {
        let twoD = """
        {"version":11,"graph":{"viewport":{"xmin":-5,"ymin":-3,"xmax":5,"ymax":3}},
         "expressions":{"list":[{"type":"expression","id":"1","color":"#c74440","latex":"y=x^2"},
                                 {"type":"expression","id":"2","latex":"a=2","sliderBounds":{"min":"0","max":"4","step":""}}]}}
        """
        let (document, skipped) = try GraphExpressionConverter.document(fromDesmosState: Data(twoD.utf8))
        XCTAssertEqual(document.mode, .twoD)
        XCTAssertEqual(document.items.map(\.latex), ["y=x^2", "a=2"])
        XCTAssertEqual(document.items.first?.color, .custom("#c74440"))
        XCTAssertEqual(document.viewport, Viewport2D(xMin: -5, xMax: 5, yMin: -3, yMax: 3))
        XCTAssertEqual(skipped, 0)

        let threeD = """
        {"version":11,"graph":{"viewport":{"xmin":-2,"ymin":-2,"zmin":-1,"xmax":2,"ymax":2,"zmax":1},"threeDMode":true},
         "expressions":{"list":[{"type":"expression","id":"s","latex":"z=x^2-y^2"}]}}
        """
        let (document3D, _) = try GraphExpressionConverter.document(fromDesmosState: Data(threeD.utf8))
        XCTAssertEqual(document3D.mode, .threeD)
        XCTAssertEqual(document3D.viewport3D.zRange, -1 ... 1)
        XCTAssertEqual(document3D.items.map(\.latex), ["z=x^2-y^2"])
    }
}
