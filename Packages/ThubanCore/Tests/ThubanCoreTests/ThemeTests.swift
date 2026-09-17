import Foundation
import XCTest
@testable import ThubanCore

final class ThemeTests: XCTestCase {

    // MARK: Helpers

    private func contrast(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        do {
            return try ColorMath.contrast(a, b)
        } catch {
            XCTFail("contrast(\(a), \(b)) threw \(error)", file: file, line: line)
            return 0
        }
    }

    private func assertContrast(_ color: String, on bg: String, atLeast target: Double, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let ratio = contrast(color, bg)
        XCTAssertGreaterThanOrEqual(
            ratio, target - 1e-9,
            "\(label) \(color) on \(bg) is \(String(format: "%.2f", ratio)):1, wanted ≥ \(target):1",
            file: file, line: line)
    }

    private func assertContrastTargets(_ theme: ResolvedTheme, label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let bg = theme.bg
        assertContrast(theme.ink, on: bg, atLeast: 7, "\(label) ink", file: file, line: line)
        assertContrast(theme.inkDim, on: bg, atLeast: 4.5, "\(label) inkDim", file: file, line: line)
        assertContrast(theme.inkFaint, on: bg, atLeast: 3.2, "\(label) inkFaint", file: file, line: line)
        for (name, text) in [("accentText", theme.accentText), ("signalText", theme.signalText),
                             ("posText", theme.posText), ("negText", theme.negText)] {
            assertContrast(text, on: bg, atLeast: 4.5, "\(label) \(name)", file: file, line: line)
        }
        assertContrast(theme.onAccent, on: theme.accent, atLeast: 3.0, "\(label) onAccent", file: file, line: line)
    }

    private let hexPattern = try? NSRegularExpression(pattern: "^#[0-9a-f]{6}$")

    private func isNormalizedHex(_ value: String) -> Bool {
        guard let hexPattern else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return hexPattern.firstMatch(in: value, range: range) != nil
    }

    // MARK: ColorMath — parsing

    func testParseHexToleratesShortLongAndUnprefixedForms() throws {
        let expected = ColorMath.RGB(r: 224, g: 177, b: 92)
        XCTAssertEqual(try ColorMath.parseHex("#e0b15c"), expected)
        XCTAssertEqual(try ColorMath.parseHex("E0B15C"), expected)
        XCTAssertEqual(try ColorMath.parseHex("  #e0b15c \n"), expected)
        XCTAssertEqual(try ColorMath.parseHex("#e0b15cff"), expected)
        XCTAssertEqual(try ColorMath.parseHex("#fa0"), ColorMath.RGB(r: 255, g: 170, b: 0))
        XCTAssertEqual(try ColorMath.parseHex("fa0"), ColorMath.RGB(r: 255, g: 170, b: 0))
        XCTAssertTrue(ColorMath.isValidHex("#ABC"))
    }

    func testParseHexRejectsGarbageWithThubanError() {
        for bad in ["", "#", "#12", "#12345", "#ggg", "brass", "#e0b15", "rgb(1,2,3)"] {
            XCTAssertFalse(ColorMath.isValidHex(bad), bad)
            XCTAssertThrowsError(try ColorMath.parseHex(bad), bad) { error in
                guard case .parse = error as? ThubanError else {
                    return XCTFail("expected ThubanError.parse for \(bad), got \(error)")
                }
            }
        }
    }

    func testToHexRoundTripsAndNormalizes() throws {
        XCTAssertEqual(ColorMath.toHex(ColorMath.RGB(r: 224, g: 177, b: 92)), "#e0b15c")
        XCTAssertEqual(try ColorMath.normalizeHex("FA0"), "#ffaa00")
        XCTAssertEqual(ColorMath.toHex(ColorMath.RGB(r: 300, g: -5, b: 127.6)), "#ff0080")
        for scheme in SchemePresets.all {
            for slot in ColorScheme.Slot.allCases {
                XCTAssertEqual(try ColorMath.normalizeHex(scheme[slot]), scheme[slot], "\(scheme.id).\(slot)")
            }
        }
    }

    // MARK: ColorMath — arithmetic

    func testShadeMovesTowardBlackBelowOneAndWhiteAboveOne() throws {
        let base = "#e0b15c"
        let darker = try ColorMath.shade(base, 0.72)
        let lighter = try ColorMath.shade(base, 1.5)
        XCTAssertEqual(darker, "#a17f42")
        XCTAssertLessThan(try ColorMath.luminance(darker), try ColorMath.luminance(base))
        XCTAssertGreaterThan(try ColorMath.luminance(lighter), try ColorMath.luminance(base))
        XCTAssertEqual(try ColorMath.shade(base, 1), base)
        XCTAssertEqual(try ColorMath.shade("#000000", 2), "#ffffff")
        XCTAssertEqual(try ColorMath.shade("#ffffff", 0), "#000000")
        XCTAssertNotEqual(try ColorMath.shade("#000000", 1.12), "#000000", "black must still be lightenable")
    }

    func testMixBlendsLinearly() throws {
        XCTAssertEqual(try ColorMath.mix("#000000", "#ffffff", 0.5), "#808080")
        XCTAssertEqual(try ColorMath.mix("#ff0000", "#0000ff", 0), "#ff0000")
        XCTAssertEqual(try ColorMath.mix("#ff0000", "#0000ff", 1), "#0000ff")
        XCTAssertEqual(try ColorMath.mix("#ff0000", "#0000ff", 7), "#0000ff", "t is clamped")
    }

    func testLuminanceAndContrastMatchWCAG() throws {
        XCTAssertEqual(try ColorMath.luminance("#000000"), 0, accuracy: 1e-12)
        XCTAssertEqual(try ColorMath.luminance("#ffffff"), 1, accuracy: 1e-12)
        XCTAssertEqual(try ColorMath.contrast("#000000", "#ffffff"), 21, accuracy: 1e-9)
        XCTAssertEqual(try ColorMath.contrast("#ffffff", "#000000"), 21, accuracy: 1e-9)
        XCTAssertEqual(try ColorMath.contrast("#e0b15c", "#e0b15c"), 1, accuracy: 1e-12)
        // Known pair: #767676 on white is the classic 4.54:1 boundary color.
        XCTAssertEqual(try ColorMath.contrast("#767676", "#ffffff"), 4.54, accuracy: 0.01)
    }

    func testLegibleReturnsInputUnchangedWhenAlreadyPassing() throws {
        XCTAssertEqual(try ColorMath.legible("#161a21", on: "#f6f2e8", target: 7), "#161a21")
        XCTAssertEqual(try ColorMath.legible("E0B15C", on: "#090b11", target: 4.5), "E0B15C", "spelling preserved")
        let rgb = ColorMath.RGB(r: 22, g: 26, b: 33)
        XCTAssertEqual(ColorMath.legible(rgb, on: .white, target: 7), rgb)
    }

    func testLegibleNudgesBrassAccentOntoLightGround() throws {
        let nudged = try ColorMath.legible("#e0b15c", on: "#f6f2e8", target: 4.5)
        XCTAssertNotEqual(nudged, "#e0b15c")
        assertContrast(nudged, on: "#f6f2e8", atLeast: 4.5, "nudged brass")
        XCTAssertLessThan(try ColorMath.luminance(nudged), try ColorMath.luminance("#e0b15c"), "walked toward black")
        // A dark color on a dark ground walks toward white instead.
        let onDark = try ColorMath.legible("#5c616e", on: "#090b11", target: 4.5)
        assertContrast(onDark, on: "#090b11", atLeast: 4.5, "faint on dark")
        XCTAssertGreaterThan(try ColorMath.luminance(onDark), try ColorMath.luminance("#5c616e"))
    }

    func testLegibleKeepsBestEffortWhenTargetIsUnreachable() throws {
        // Mid-grey ground: nothing reaches 21:1, so legible must return the highest contrast it found.
        let result = try ColorMath.legible("#808080", on: "#808080", target: 21)
        XCTAssertNotEqual(result, "#808080")
        XCTAssertGreaterThan(try ColorMath.contrast(result, "#808080"), 3)
    }

    func testOnAccentPicksDarkInkForBrassAndLightForDeepFills() throws {
        XCTAssertEqual(try ColorMath.onAccent("#e0b15c"), ColorMath.darkOnAccent)
        XCTAssertEqual(try ColorMath.onAccent("#1a1a1a"), ColorMath.lightOnAccent)
        XCTAssertEqual(try ColorMath.onAccent("#3b2a80"), ColorMath.lightOnAccent, "deep violet takes light ink")
        XCTAssertEqual(try ColorMath.onAccent("#c4566b"), ColorMath.darkOnAccent, "rose neg (~0.2 luminance) still favors dark ink")
    }

    // MARK: HSL

    func testHSLRoundTripIsExactForPresetColors() throws {
        for scheme in SchemePresets.all {
            for slot in ColorScheme.Slot.allCases {
                let hex = scheme[slot]
                XCTAssertEqual(ColorMath.hslToHex(try ColorMath.hexToHSL(hex)), hex, "\(scheme.id).\(slot)")
            }
        }
        for grey in ["#000000", "#ffffff", "#808080"] {
            let hsl = try ColorMath.hexToHSL(grey)
            XCTAssertEqual(hsl.s, 0, accuracy: 1e-12)
            XCTAssertEqual(ColorMath.hslToHex(hsl), grey)
        }
        let red = try ColorMath.hexToHSL("#ff0000")
        XCTAssertEqual(red.h, 0, accuracy: 1e-9)
        XCTAssertEqual(red.s, 1, accuracy: 1e-9)
        XCTAssertEqual(red.l, 0.5, accuracy: 1e-9)
        XCTAssertEqual(try ColorMath.hexToHSL("#00ff00").h, 120, accuracy: 1e-9)
        XCTAssertEqual(try ColorMath.hexToHSL("#0000ff").h, 240, accuracy: 1e-9)
    }

    func testHSLWrapsHueAndClampsComponents() {
        XCTAssertEqual(ColorMath.HSL(h: -30, s: 0.5, l: 0.5).h, 330, accuracy: 1e-9)
        XCTAssertEqual(ColorMath.HSL(h: 725, s: 2, l: -1).h, 5, accuracy: 1e-9)
        XCTAssertEqual(ColorMath.HSL(h: 0, s: 2, l: -1).s, 1)
        XCTAssertEqual(ColorMath.HSL(h: 0, s: 2, l: -1).l, 0)
        XCTAssertEqual(ColorMath.HSL(h: 350, s: 0.5, l: 0.5).rotated(by: 20).h, 10, accuracy: 1e-9)
    }

    // MARK: Presets and selection

    func testPresetsAreEightInAtlasOrderWithDistinctIds() {
        XCTAssertEqual(SchemePresets.all.map(\.id),
                       ["brass", "cobalt", "emerald", "rose", "violet", "slate", "ember", "moss"])
        XCTAssertEqual(SchemePresets.defaultId, "brass")
        XCTAssertEqual(SchemePresets.default, SchemePresets.brass)
        XCTAssertEqual(SchemePresets.brass.accent, "#e0b15c")
        XCTAssertEqual(SchemePresets.moss.lightPanel, "#fbfcf2")
        XCTAssertNil(SchemePresets.scheme(id: "custom"))
        XCTAssertEqual(SchemePresets.scheme(id: "ember")?.label, "Ember")
        for scheme in SchemePresets.all {
            XCTAssertNoThrow(try scheme.validate(), scheme.id)
        }
    }

    func testThemeSelectionDefaultsAndTolerantDecoding() throws {
        let selection = ThemeSelection()
        XCTAssertEqual(selection.mode, .auto)
        XCTAssertEqual(selection.schemeId, "brass")
        XCTAssertNil(selection.custom)
        XCTAssertEqual(selection, ThemeSelection.default)

        let decoder = JSONDecoder()
        let empty = try decoder.decode(ThemeSelection.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .default)

        let partial = try decoder.decode(ThemeSelection.self, from: Data(#"{"mode":"dark"}"#.utf8))
        XCTAssertEqual(partial.mode, .dark)
        XCTAssertEqual(partial.schemeId, "brass")

        var custom = ThemeSelection(mode: .light, schemeId: ColorScheme.customId, custom: SchemePresets.rose.asCustom())
        custom.custom?.accent = "#123456"
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try decoder.decode(ThemeSelection.self, from: data), custom)
    }

    func testSelectionResolvesModeAndUnknownIdsToBrass() {
        XCTAssertFalse(ThemeSelection(mode: .light).isDark(systemIsDark: true))
        XCTAssertTrue(ThemeSelection(mode: .dark).isDark(systemIsDark: false))
        XCTAssertTrue(ThemeSelection(mode: .auto).isDark(systemIsDark: true))
        XCTAssertFalse(ThemeSelection(mode: .auto).isDark(systemIsDark: false))

        XCTAssertEqual(ThemeSelection(schemeId: "nope").effectiveScheme, SchemePresets.brass)
        XCTAssertEqual(ThemeSelection(schemeId: ColorScheme.customId, custom: nil).effectiveScheme, SchemePresets.brass)
        XCTAssertEqual(ThemeSelection(schemeId: "slate").effectiveScheme, SchemePresets.slate)
    }

    // MARK: Resolver

    func testEveryPresetInBothModesMeetsContrastTargets() {
        for scheme in SchemePresets.all {
            for isDark in [false, true] {
                let theme = ThemeResolver.resolve(ThemeSelection(mode: isDark ? .dark : .light, schemeId: scheme.id),
                                                  systemIsDark: !isDark)
                XCTAssertEqual(theme.isDark, isDark)
                XCTAssertEqual(theme.schemeId, scheme.id)
                XCTAssertEqual(theme.bg, scheme.background(isDark: isDark))
                XCTAssertEqual(theme.panel, scheme.panel(isDark: isDark))
                assertContrastTargets(theme, label: "\(scheme.id) \(isDark ? "dark" : "light")")
            }
        }
    }

    func testBrassLightAccentTextIsLegibleOnBrassGround() {
        let theme = ThemeResolver.resolve(ThemeSelection(mode: .light), systemIsDark: true)
        XCTAssertEqual(theme.bg, "#f6f2e8")
        assertContrast(theme.accentText, on: "#f6f2e8", atLeast: 4.5, "brass light accentText")
        XCTAssertNotEqual(theme.accentText, "#e0b15c", "raw brass is only ~1.9:1 on the light ground")
        XCTAssertEqual(theme.onAccent, ColorMath.darkOnAccent)
        XCTAssertEqual(theme.accentDeep, "#a17f42", "accent-deep = accent × 0.72 as in Atlas")
        XCTAssertEqual(theme.inkRGB, "22,26,33")
    }

    func testFillsKeepRawSchemeValuesInLightMode() {
        // Fills are the brief's raw slot colours (brass stays brass on the light ground); only the *Text variants
        // are walked to 4.5:1 and onAccent is chosen for the raw fill.
        let theme = ThemeResolver.resolve(ThemeSelection(mode: .light), systemIsDark: false)
        XCTAssertEqual(theme.accent, "#e0b15c")
        XCTAssertEqual(theme.signal, "#74d6c4")
        XCTAssertEqual(theme.pos, "#5fd08a")
        XCTAssertEqual(theme.neg, "#e08c8c")
        XCTAssertEqual(theme.accentRGB, "224,177,92")
        XCTAssertEqual(theme.onAccent, ColorMath.darkOnAccent)
        for scheme in SchemePresets.all {
            let light = ThemeResolver.resolve(scheme: scheme, isDark: false)
            XCTAssertEqual(light.accent, scheme.accent.lowercased(), "\(scheme.id) light accent fill is the raw slot")
            XCTAssertEqual(light.signal, scheme.signal.lowercased(), "\(scheme.id) light signal fill is the raw slot")
            XCTAssertEqual(light.pos, scheme.pos.lowercased(), "\(scheme.id) light pos fill is the raw slot")
            XCTAssertEqual(light.neg, scheme.neg.lowercased(), "\(scheme.id) light neg fill is the raw slot")
        }
    }

    func testBrassDarkKeepsRawChromaAndDarkInkOnAccent() {
        let theme = ThemeResolver.resolve(ThemeSelection(mode: .auto), systemIsDark: true)
        XCTAssertTrue(theme.isDark)
        XCTAssertEqual(theme.accent, "#e0b15c", "fills are always the raw slot value")
        XCTAssertEqual(theme.accentText, "#e0b15c")
        XCTAssertEqual(theme.signal, "#74d6c4")
        XCTAssertEqual(theme.pos, "#5fd08a")
        XCTAssertEqual(theme.neg, "#e08c8c")
        XCTAssertEqual(theme.ink, "#e9e7df")
        XCTAssertEqual(theme.onAccent, ColorMath.darkOnAccent)
        XCTAssertEqual(theme.inkRGB, "202,214,242")
        XCTAssertEqual(theme.accentRGB, "224,177,92")
    }

    func testDerivedTokensFollowContractMixes() throws {
        let theme = ThemeResolver.resolve(ThemeSelection(mode: .light), systemIsDark: false)
        XCTAssertEqual(theme.panel2, try ColorMath.mix("#fffdf7", theme.ink, 0.06))
        XCTAssertEqual(theme.line, try ColorMath.mix("#f6f2e8", "#161a21", 0.08))
        XCTAssertEqual(theme.line2, try ColorMath.mix("#f6f2e8", "#161a21", 0.15))
        XCTAssertEqual(theme.accentTint, try ColorMath.mix("#fffdf7", "#e0b15c", 0.14))
        XCTAssertEqual(theme.posSoft, try ColorMath.mix("#fffdf7", "#5fd08a", 0.18))
        XCTAssertEqual(theme.negSoft, try ColorMath.mix("#fffdf7", "#e08c8c", 0.18))
        XCTAssertEqual(theme.warnSoft, try ColorMath.mix("#fffdf7", "#e0b15c", 0.18))
        XCTAssertEqual(theme.signalSoft, try ColorMath.mix("#fffdf7", "#74d6c4", 0.18))
    }

    func testAllResolvedTokensAreNormalizedHex() {
        let theme = ThemeResolver.resolve(ThemeSelection(schemeId: "violet"), systemIsDark: false)
        for (name, value) in theme.cssVariablePairs where !name.hasSuffix("-rgb") {
            XCTAssertTrue(isNormalizedHex(value), "\(name) = \(value)")
        }
    }

    func testCSSVariablesContainsEveryToken() {
        let theme = ThemeResolver.resolve(.default, systemIsDark: false)
        let css = theme.cssVariables
        XCTAssertTrue(css.hasPrefix(":root{"))
        XCTAssertTrue(css.hasSuffix("}"))
        XCTAssertFalse(css.contains(" "), "compact, no whitespace")
        let expected = [
            "bg", "panel", "panel-2", "line", "line-2", "ink", "ink-dim", "ink-faint",
            "accent", "accent-text", "accent-deep", "accent-tint", "on-accent",
            "signal", "signal-text", "pos", "pos-text", "neg", "neg-text",
            "pos-soft", "neg-soft", "warn-soft", "signal-soft", "ink-rgb", "accent-rgb",
        ]
        for name in expected {
            XCTAssertTrue(css.contains("--\(name):"), "missing --\(name)")
        }
        XCTAssertEqual(ResolvedTheme.cssTokenNames.count, 23)
        XCTAssertEqual(theme.cssVariablePairs.count, expected.count)
        XCTAssertTrue(css.contains("--bg:#f6f2e8;"))
        XCTAssertTrue(css.contains("--ink-rgb:22,26,33;"))
        XCTAssertTrue(css.contains("--accent-rgb:"))
        // Every declaration is well-formed `--name:value`.
        let body = css.dropFirst(":root{".count).dropLast()
        for declaration in body.split(separator: ";") {
            XCTAssertTrue(declaration.hasPrefix("--"), String(declaration))
            XCTAssertEqual(declaration.filter { $0 == ":" }.count, 1, String(declaration))
        }
    }

    // MARK: Custom schemes

    func testCustomSchemeWithBadHexFallsBackToBrassValues() {
        var custom = SchemePresets.cobalt.asCustom()
        custom.accent = "not a color"
        custom.lightBg = "#12"
        custom.darkPanel = ""
        let selection = ThemeSelection(mode: .light, schemeId: ColorScheme.customId, custom: custom)

        let effective = selection.effectiveScheme
        XCTAssertEqual(effective.accent, SchemePresets.brass.accent)
        XCTAssertEqual(effective.lightBg, SchemePresets.brass.lightBg)
        XCTAssertEqual(effective.darkPanel, SchemePresets.brass.darkPanel)
        XCTAssertEqual(effective.signal, SchemePresets.cobalt.signal, "valid slots are kept")
        XCTAssertEqual(Set(custom.invalidSlots), [.accent, .lightBg, .darkPanel])
        XCTAssertThrowsError(try custom.validate()) { error in
            guard case .parse(let detail)? = error as? ThubanError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("Accent"))
            XCTAssertTrue(detail.contains("Light background"))
        }

        let light = ThemeResolver.resolve(selection, systemIsDark: true)
        let brassLight = ThemeResolver.resolve(ThemeSelection(mode: .light), systemIsDark: true)
        XCTAssertEqual(light.bg, brassLight.bg)
        XCTAssertEqual(light.accent, brassLight.accent)
        XCTAssertEqual(light.accentText, brassLight.accentText)
        XCTAssertEqual(light.schemeId, ColorScheme.customId)
        assertContrastTargets(light, label: "custom-with-fallbacks light")

        let dark = ThemeResolver.resolve(ThemeSelection(mode: .dark, schemeId: ColorScheme.customId, custom: custom),
                                         systemIsDark: false)
        XCTAssertEqual(dark.panel, SchemePresets.brass.darkPanel)
        XCTAssertEqual(dark.bg, SchemePresets.cobalt.darkBg)
        assertContrastTargets(dark, label: "custom-with-fallbacks dark")
    }

    func testSanitizedNormalizesSpellingAndSubscriptRoundTrips() {
        var scheme = SchemePresets.brass.asCustom(label: "Mine")
        scheme[.accent] = "FA0"
        scheme[.neg] = " #E08C8C "
        let clean = scheme.sanitized()
        XCTAssertEqual(clean.accent, "#ffaa00")
        XCTAssertEqual(clean.neg, "#e08c8c")
        XCTAssertEqual(clean.id, ColorScheme.customId)
        XCTAssertEqual(clean.label, "Mine")
        XCTAssertTrue(clean.isCustom)
        XCTAssertEqual(ColorScheme.Slot.allCases.map(\.label),
                       ["Accent", "Highlight", "Gain", "Loss", "Dark background", "Dark surface",
                        "Light background", "Light surface"])
    }

    // MARK: Cards

    func testSchemeCardModelsForSettingsGrid() {
        let cards = SchemeCardModel.presets
        XCTAssertEqual(cards.count, 8)
        XCTAssertEqual(cards.map(\.id), SchemePresets.all.map(\.id))
        XCTAssertEqual(cards.filter(\.isDefault).map(\.id), ["brass"])
        for (card, scheme) in zip(cards, SchemePresets.all) {
            XCTAssertEqual(card.label, scheme.label)
            XCTAssertEqual(card.dots, [scheme.accent, scheme.signal, scheme.pos, scheme.neg])
            XCTAssertEqual(card.lightBg, scheme.lightBg)
            XCTAssertEqual(card.lightPanel, scheme.lightPanel)
            XCTAssertEqual(card.darkBg, scheme.darkBg)
            XCTAssertEqual(card.darkPanel, scheme.darkPanel)
        }

        let nine = SchemeCardModel.cards(for: .default)
        XCTAssertEqual(nine.count, 9)
        let customCard = nine[8]
        XCTAssertEqual(customCard.id, ColorScheme.customId)
        XCTAssertEqual(customCard.label, SchemeCardModel.customLabel)
        XCTAssertFalse(customCard.isDefault)
        XCTAssertEqual(customCard.dots, SchemeCardModel.presets[0].dots, "no custom yet → brass preview")

        var edited = SchemePresets.rose.asCustom()
        edited.accent = "bogus"
        let editedCard = SchemeCardModel.customCard(edited)
        XCTAssertEqual(editedCard.dots[0], SchemePresets.brass.accent, "invalid slot previews as brass")
        XCTAssertEqual(editedCard.dots[1], SchemePresets.rose.signal)
    }

    // MARK: Deriver

    func testSchemeDeriverRotatesHueAndKeepsLightness() throws {
        let accent = "#e0b15c"
        let base = try ColorMath.hexToHSL(accent)
        let proposal = try SchemeDeriver.derive(fromAccent: accent)
        let expectations: [(String, Double)] = [(proposal.signal, 150), (proposal.pos, 100), (proposal.neg, -30)]
        for (hex, rotation) in expectations {
            XCTAssertTrue(isNormalizedHex(hex), hex)
            let hsl = try ColorMath.hexToHSL(hex)
            XCTAssertEqual(hsl.h, ColorMath.HSL.wrapHue(base.h + rotation), accuracy: 1.0, "hue for \(rotation)°")
            XCTAssertEqual(hsl.l, base.l, accuracy: 0.01, "lightness for \(rotation)°")
            XCTAssertEqual(hsl.s, base.s, accuracy: 0.02, "saturation for \(rotation)°")
        }
        XCTAssertEqual(try SchemeDeriver.rotate("#ff0000", by: 120), "#00ff00")
        XCTAssertEqual(try SchemeDeriver.rotate("#ff0000", by: -120), "#0000ff")
        XCTAssertThrowsError(try SchemeDeriver.derive(fromAccent: "nope")) { error in
            guard case .parse = error as? ThubanError else { return XCTFail("\(error)") }
        }
    }

    func testSchemeDeriverAppliesToSchemeWithoutTouchingGrounds() throws {
        let applied = try SchemeDeriver.applying(accent: "6AA8FF", to: SchemePresets.brass.asCustom())
        XCTAssertEqual(applied.accent, "#6aa8ff")
        XCTAssertEqual(applied.signal, try SchemeDeriver.derive(fromAccent: "#6aa8ff").signal)
        XCTAssertEqual(applied.lightBg, SchemePresets.brass.lightBg)
        XCTAssertEqual(applied.darkBg, SchemePresets.brass.darkBg)
        XCTAssertEqual(applied.id, ColorScheme.customId)
        XCTAssertNoThrow(try applied.validate())
        let theme = ThemeResolver.resolve(scheme: applied, isDark: false)
        assertContrastTargets(theme, label: "derived custom light")
    }
}
