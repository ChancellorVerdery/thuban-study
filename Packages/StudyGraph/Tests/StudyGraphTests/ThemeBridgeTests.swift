import Foundation
import GraphTheme
@testable import StudyGraph
import ThubanCore
import ThubanGraphKit
import XCTest

/// `GraphKitTheme(study:)` is a field copy of Study's resolved theme, and for every preset scheme (light and dark)
/// it resolves exactly what Thuban Graph resolves for the same scheme (STUDY_INTEGRATION.md §8).
@MainActor
final class ThemeBridgeTests: XCTestCase {
    func testEveryPresetLightAndDark() {
        XCTAssertEqual(ThubanCore.SchemePresets.all.map(\.id), GraphTheme.SchemePresets.all.map(\.id), "Study and Graph ship the same schemes")
        for scheme in ThubanCore.SchemePresets.all {
            for dark in [false, true] {
                let study = ThubanCore.ThemeResolver.resolve(
                    ThubanCore.ThemeSelection(mode: dark ? .dark : .light, schemeId: scheme.id, custom: nil), systemIsDark: dark)
                let kit = GraphKitTheme(study: study)
                let t = kit.theme
                let label = "\(scheme.id) \(dark ? "dark" : "light")"
                // Field copy.
                XCTAssertEqual([t.bg, t.panel, t.panel2, t.line, t.line2, t.ink, t.inkDim, t.inkFaint, t.accent, t.accentText,
                                t.accentDeep, t.accentTint, t.onAccent, t.signal, t.signalText, t.pos, t.posText, t.neg, t.negText,
                                t.posSoft, t.negSoft, t.warnSoft, t.signalSoft, t.inkRGB, t.accentRGB, t.schemeId],
                               [study.bg, study.panel, study.panel2, study.line, study.line2, study.ink, study.inkDim, study.inkFaint,
                                study.accent, study.accentText, study.accentDeep, study.accentTint, study.onAccent, study.signal,
                                study.signalText, study.pos, study.posText, study.neg, study.negText, study.posSoft, study.negSoft,
                                study.warnSoft, study.signalSoft, study.inkRGB, study.accentRGB, study.schemeId], label)
                XCTAssertEqual(t.isDark, study.isDark, label)
                // Identical to Graph's own resolution of the scheme (theme, series palette, paper).
                let graph = GraphKitTheme(selection: GraphTheme.ThemeSelection(mode: dark ? .dark : .light, schemeId: scheme.id, custom: nil),
                                          systemIsDark: dark)
                // Graph draws Brass from its exact design values (BrassDesign); Study keeps its own Brass chrome, so
                // only the series colors must agree there. Every other scheme resolves identically.
                if scheme.id != "brass" { XCTAssertEqual(kit.theme, graph.theme, label) }
                XCTAssertEqual(kit.palette, graph.palette, label)
                XCTAssertEqual(kit.paper, graph.paper, label)
            }
        }
    }

    func testCustomSchemeStillCopies() {
        var selection = ThubanCore.ThemeSelection(mode: .dark, schemeId: ThubanCore.ColorScheme.customId, custom: nil)
        selection.custom = ThubanCore.SchemePresets.all[2].asCustom(label: "Mine")
        let study = ThubanCore.ThemeResolver.resolve(selection, systemIsDark: true)
        let kit = GraphKitTheme(study: study)
        XCTAssertEqual(kit.theme.accent, study.accent)
        XCTAssertEqual(kit.theme.signal, study.signal)
        XCTAssertEqual(kit.theme.accentStrong, study.accentText)
        XCTAssertEqual(kit.theme.track, study.panel2)
        XCTAssertEqual(kit.palette, GraphPalette.resolve(kit.theme))
    }

    func testPaperFromOtherTokens() {
        let light = ThubanCore.ThemeResolver.resolve(ThubanCore.ThemeSelection(mode: .light, schemeId: "cobalt", custom: nil), systemIsDark: false)
        let dark = ThubanCore.ThemeResolver.resolve(ThubanCore.ThemeSelection(mode: .dark, schemeId: "cobalt", custom: nil), systemIsDark: true)
        let kit = GraphKitTheme(study: light, paper: dark)
        XCTAssertFalse(kit.theme.isDark)
        XCTAssertEqual(kit.paper, GraphPalette.resolve(GraphKitTheme.bridge(dark)))
        XCTAssertNotEqual(kit.paper, kit.palette)
    }
}
