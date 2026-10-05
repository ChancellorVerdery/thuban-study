import Foundation
import XCTest
@testable import ThubanCore

/// Equations suggested by imports: decoding the suggester's reply, never repeating the sheet or an earlier (or
/// declined) suggestion, and approval adding an entry to the right group.
final class EquationSuggestionTests: XCTestCase {
    private func makeStore() throws -> Store {
        let locations = try StoreLocations.temporary(inMemoryDatabase: true)
        let store = try Store.open(locations)
        addTeardownBlock { try? FileManager.default.removeItem(at: locations.documents.deletingLastPathComponent()) }
        return store
    }

    func testRepliesDecodeLeniently() {
        let classId = ClassID.new()
        let input: JSONValue = ["suggestions": [
            ["group": "Ideal gas", "name": "Ideal gas law", "equations": ["PV = mRT"], "kind": "equation", "reason": "Q2, Q5"],
            ["group": "Constants", "name": "Universal gas constant", "equations": "R_u = 8.314", "kind": "constant", "note": ""],
            ["group": "x", "name": "", "equations": ["a=b"], "kind": "equation", "reason": "-"],
            ["group": "x", "name": "Blank", "equations": [" "], "kind": "equation", "reason": "-"],
        ]]
        let decoded = EquationSuggester.suggestions(from: input, classId: classId, documentId: nil)
        XCTAssertEqual(decoded.map(\.name), ["Ideal gas law", "Universal gas constant"])
        XCTAssertEqual(decoded[1].kind, .constant)
        XCTAssertEqual(decoded[1].equations, ["R_u = 8.314"], "a single string is one equation")
        XCTAssertNil(decoded[1].note, "an empty note is no note")
        XCTAssertTrue(decoded.allSatisfy { $0.status == .pending })
    }

    func testNothingOnTheSheetOrSuggestedBeforeIsRepeated() {
        let classId = ClassID.new()
        let group = EquationGroup(classId: classId, name: "Gases")
        let sheet = EquationSheet(classId: classId, sections: [
            .init(group: group, entries: [EquationEntry(groupId: group.id, name: "Ideal gas", equations: ["PV=mRT"])]),
        ])
        let denied = EquationSuggestion(classId: classId, groupName: "Gases", name: "Combined gas law", equations: ["\\frac{P_1V_1}{T_1}=\\frac{P_2V_2}{T_2}"], status: .denied)
        let fresh = [
            EquationSuggestion(classId: classId, groupName: "Gases", name: "Ideal gas law", equations: ["P V = m R T"]),
            EquationSuggestion(classId: classId, groupName: "Gases", name: "Combined gas law", equations: ["P_1V_1/T_1 = P_2V_2/T_2"]),
            EquationSuggestion(classId: classId, groupName: "Work", name: "Boundary work", equations: ["W_b = \\int P\\,dV"]),
            EquationSuggestion(classId: classId, groupName: "Work", name: "Boundary work", equations: ["W = \\int_1^2 P dV"]),
        ]
        let novel = EquationSuggester.novel(fresh, sheet: sheet, earlier: [denied])
        XCTAssertEqual(novel.map(\.name), ["Boundary work"], "the sheet's equation, a declined name and a repeat are dropped")
    }

    func testThePromptListsTheSheetAndTheDeclined() {
        let classId = ClassID.new()
        let group = EquationGroup(classId: classId, name: "Gases")
        let sheet = EquationSheet(classId: classId, sections: [
            .init(group: group, entries: [EquationEntry(groupId: group.id, name: "Ideal gas", equations: ["PV=mRT"])]),
        ])
        let denied = EquationSuggestion(classId: classId, groupName: "Gases", name: "Combined gas law", equations: ["x"], status: .denied)
        let question = Question(classId: classId, kind: .shortAnswer, stem: "A tank holds 2 kg of air at 300 K.", parts: [])
        let message = EquationSuggester.message(batch: [question], classContext: "Thermodynamics", sheet: sheet, earlier: [denied])
        XCTAssertTrue(message.contains("## Gases"))
        XCTAssertTrue(message.contains("Ideal gas: PV=mRT"))
        XCTAssertTrue(message.contains("Declined by the student"))
        XCTAssertTrue(message.contains("1. A tank holds 2 kg"))
        XCTAssertTrue(EquationSuggester.system.contains("PV = mRT, never P_1V_1 = P_2V_2"))
    }

    func testApprovingAddsToItsGroupAndDenyingKeepsItOut() async throws {
        let store = try makeStore()
        let studyClass = StudyClass(name: "Thermodynamics")
        try await store.insert(studyClass)
        let existing = try await store.addEquationGroup(named: "Ideal gas", to: studyClass.id)
        let a = EquationSuggestion(classId: studyClass.id, groupName: "ideal GAS", name: "Ideal gas law", equations: ["PV=mRT"], note: "T in K")
        let b = EquationSuggestion(classId: studyClass.id, groupName: "Constants", name: "g", equations: ["g = 9.81\\ \\mathrm{m/s^2}"], kind: .constant)
        let c = EquationSuggestion(classId: studyClass.id, groupName: "Work", name: "Boundary work", equations: ["W_b=\\int P\\,dV"])
        try await store.addEquationSuggestions([a, b, c])
        let pendingBefore = try await store.equationSuggestions(in: studyClass.id, status: .pending)
        XCTAssertEqual(pendingBefore.count, 3)

        try await store.approveEquationSuggestion(a.id)
        try await store.approveEquationSuggestion(b.id)
        try await store.setEquationSuggestionStatus(c.id, to: .denied)

        let sheet = try await store.equationSheet(for: studyClass.id)
        XCTAssertEqual(sheet.groups.map(\.name), ["Ideal gas", "Constants"], "an existing group is matched ignoring case; a missing one is made")
        XCTAssertEqual(sheet.sections.first { $0.group.id == existing.id }?.entries.map(\.name), ["Ideal gas law"])
        XCTAssertEqual(sheet.sections.first { $0.group.id == existing.id }?.entries.first?.note, "T in K")
        let pendingAfter = try await store.equationSuggestions(in: studyClass.id, status: .pending)
        XCTAssertTrue(pendingAfter.isEmpty)
        let denied = try await store.equationSuggestions(in: studyClass.id, status: .denied)
        XCTAssertEqual(denied.map(\.name), ["Boundary work"], "a denied suggestion is kept, so it is never suggested again")
    }
}
