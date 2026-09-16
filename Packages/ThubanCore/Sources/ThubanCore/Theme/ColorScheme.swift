import Foundation

/// Light/dark preference. `auto` follows macOS.
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case auto, light, dark

    /// Segmented-control label.
    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Whether this mode renders dark given the current system appearance.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .auto: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }
}

/// A color scheme: the four chromatic slots plus a background/panel pair per mode. All values are hex strings
/// (`#rrggbb`). The ink ramp is not part of a scheme; it is shared per mode (see `InkRamp`).
public struct ColorScheme: Codable, Sendable, Equatable, Identifiable {
    /// Scheme id used by `ThemeSelection.schemeId` when the scheme is user-edited.
    public static let customId = "custom"

    public var id: String
    public var label: String
    public var accent: String
    /// "Highlight" in the editor.
    public var signal: String
    /// "Gain" in the editor.
    public var pos: String
    /// "Loss" in the editor.
    public var neg: String
    public var darkBg: String
    public var darkPanel: String
    public var lightBg: String
    public var lightPanel: String

    public init(id: String, label: String, accent: String, signal: String, pos: String, neg: String,
                darkBg: String, darkPanel: String, lightBg: String, lightPanel: String) {
        self.id = id
        self.label = label
        self.accent = accent
        self.signal = signal
        self.pos = pos
        self.neg = neg
        self.darkBg = darkBg
        self.darkPanel = darkPanel
        self.lightBg = lightBg
        self.lightPanel = lightPanel
    }

    /// The eight editable slots of a scheme, in editor order.
    public enum Slot: String, CaseIterable, Codable, Sendable {
        case accent, signal, pos, neg, darkBg, darkPanel, lightBg, lightPanel

        /// Editor row label.
        public var label: String {
            switch self {
            case .accent: return "Accent"
            case .signal: return "Highlight"
            case .pos: return "Gain"
            case .neg: return "Loss"
            case .darkBg: return "Dark background"
            case .darkPanel: return "Dark surface"
            case .lightBg: return "Light background"
            case .lightPanel: return "Light surface"
            }
        }
    }

    /// Slot access by name, for the custom editor's row list.
    public subscript(slot: Slot) -> String {
        get {
            switch slot {
            case .accent: return accent
            case .signal: return signal
            case .pos: return pos
            case .neg: return neg
            case .darkBg: return darkBg
            case .darkPanel: return darkPanel
            case .lightBg: return lightBg
            case .lightPanel: return lightPanel
            }
        }
        set {
            switch slot {
            case .accent: accent = newValue
            case .signal: signal = newValue
            case .pos: pos = newValue
            case .neg: neg = newValue
            case .darkBg: darkBg = newValue
            case .darkPanel: darkPanel = newValue
            case .lightBg: lightBg = newValue
            case .lightPanel: lightPanel = newValue
            }
        }
    }

    public var isCustom: Bool { id == ColorScheme.customId }

    /// Ground for the given mode.
    public func background(isDark: Bool) -> String { isDark ? darkBg : lightBg }

    /// Surface for the given mode.
    public func panel(isDark: Bool) -> String { isDark ? darkPanel : lightPanel }

    /// Slots whose value is not a parseable hex color.
    public var invalidSlots: [Slot] {
        Slot.allCases.filter { !ColorMath.isValidHex(self[$0]) }
    }

    /// Throws `ThubanError.parse` naming every slot that is not a hex color.
    public func validate() throws {
        let bad = invalidSlots
        guard bad.isEmpty else {
            let names = bad.map(\.label).joined(separator: ", ")
            throw ThubanError.parse("Invalid color for \(names). Use #rgb or #rrggbb.")
        }
    }

    /// A copy where every invalid slot takes `fallback`'s value for that slot and every valid one is normalized to
    /// lower-case `#rrggbb`. Never throws; this is what `ThemeResolver` renders.
    public func sanitized(fallback: ColorScheme = SchemePresets.default) -> ColorScheme {
        var copy = self
        for slot in Slot.allCases {
            copy[slot] = (try? ColorMath.normalizeHex(self[slot])) ?? fallback[slot]
        }
        return copy
    }

    /// The same values under the `custom` id, as a starting point for the editor ("Start from").
    public func asCustom(label: String = "Custom") -> ColorScheme {
        var copy = self
        copy.id = ColorScheme.customId
        copy.label = label
        return copy
    }
}

/// The eight built-in schemes (values from Atlas, see `docs/atlas-theme.md`), in settings-grid order.
public enum SchemePresets {
    public static let defaultId = "brass"

    public static let brass = ColorScheme(
        id: "brass", label: "Brass", accent: "#e0b15c", signal: "#74d6c4", pos: "#5fd08a", neg: "#e08c8c",
        darkBg: "#090b11", darkPanel: "#0e1219", lightBg: "#f6f2e8", lightPanel: "#fffdf7")
    public static let cobalt = ColorScheme(
        id: "cobalt", label: "Cobalt", accent: "#6aa8ff", signal: "#7de0c8", pos: "#5fd08a", neg: "#ef7d7d",
        darkBg: "#080b14", darkPanel: "#0d1220", lightBg: "#eef2f8", lightPanel: "#ffffff")
    public static let emerald = ColorScheme(
        id: "emerald", label: "Emerald", accent: "#5fd08a", signal: "#8ec9f0", pos: "#7ad6a0", neg: "#e58f7d",
        darkBg: "#08110d", darkPanel: "#0d1a14", lightBg: "#edf3ee", lightPanel: "#fbfffb")
    public static let rose = ColorScheme(
        id: "rose", label: "Rose", accent: "#f08a9b", signal: "#8ab6f0", pos: "#6fc3b8", neg: "#c4566b",
        darkBg: "#110a0e", darkPanel: "#1a1016", lightBg: "#f7efe6", lightPanel: "#fffaf3")
    public static let violet = ColorScheme(
        id: "violet", label: "Violet", accent: "#b28cf0", signal: "#7de0c8", pos: "#79d0b0", neg: "#e0708f",
        darkBg: "#0c0912", darkPanel: "#13101f", lightBg: "#f2eff7", lightPanel: "#fdfbff")
    public static let slate = ColorScheme(
        id: "slate", label: "Slate", accent: "#cad6f2", signal: "#9fb3d9", pos: "#86c9a4", neg: "#d98f92",
        darkBg: "#0a0c10", darkPanel: "#10141b", lightBg: "#f1f2f4", lightPanel: "#ffffff")
    public static let ember = ColorScheme(
        id: "ember", label: "Ember", accent: "#f0894f", signal: "#f0c463", pos: "#8fc98a", neg: "#d95f5f",
        darkBg: "#120b08", darkPanel: "#1b110c", lightBg: "#f8efe6", lightPanel: "#fffaf4")
    public static let moss = ColorScheme(
        id: "moss", label: "Moss", accent: "#a8c060", signal: "#7fc9a8", pos: "#86c060", neg: "#d98a6a",
        darkBg: "#0d1008", darkPanel: "#141810", lightBg: "#f2f2e4", lightPanel: "#fbfcf2")

    /// All presets in grid order: brass, cobalt, emerald, rose, violet, slate, ember, moss.
    public static let all: [ColorScheme] = [brass, cobalt, emerald, rose, violet, slate, ember, moss]

    /// The default scheme (brass).
    public static var `default`: ColorScheme { brass }

    /// The preset with this id, or nil (also nil for `"custom"`).
    public static func scheme(id: String) -> ColorScheme? {
        all.first { $0.id == id }
    }
}

/// The ink ramp shared by every scheme in one mode. `inkRGB` is the triplet Atlas uses for hairlines and
/// `rgba(var(--ink-rgb), a)`; in dark mode it is deliberately cooler than `ink`.
public struct InkRamp: Sendable, Equatable {
    public var ink: String
    public var inkDim: String
    public var inkFaint: String
    /// `"r,g,b"`.
    public var inkRGB: String

    public init(ink: String, inkDim: String, inkFaint: String, inkRGB: String) {
        self.ink = ink
        self.inkDim = inkDim
        self.inkFaint = inkFaint
        self.inkRGB = inkRGB
    }

    public static let light = InkRamp(ink: "#161a21", inkDim: "#535a68", inkFaint: "#858c9b", inkRGB: "22,26,33")
    public static let dark = InkRamp(ink: "#e9e7df", inkDim: "#9aa0ad", inkFaint: "#5c616e", inkRGB: "202,214,242")

    public static func ramp(isDark: Bool) -> InkRamp { isDark ? dark : light }

    /// `inkRGB` as a color, for hairline mixing. Falls back to `ink` if the triplet is malformed.
    public var lineInk: ColorMath.RGB {
        let parts = inkRGB.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 3 { return ColorMath.RGB(r: parts[0], g: parts[1], b: parts[2]) }
        return (try? ColorMath.parseHex(ink)) ?? .black
    }
}

/// What the user picked in Settings; persisted under `SettingsKey.theme`. Decoding tolerates missing keys so
/// older payloads fall back to the defaults (auto / brass).
public struct ThemeSelection: Codable, Sendable, Equatable {
    public var mode: AppearanceMode
    /// A preset id or `ColorScheme.customId`.
    public var schemeId: String
    /// Used only when `schemeId == ColorScheme.customId`.
    public var custom: ColorScheme?

    public init(mode: AppearanceMode = .auto, schemeId: String = SchemePresets.defaultId, custom: ColorScheme? = nil) {
        self.mode = mode
        self.schemeId = schemeId
        self.custom = custom
    }

    /// Auto mode, brass, no custom scheme.
    public static let `default` = ThemeSelection()

    private enum CodingKeys: String, CodingKey { case mode, schemeId, custom }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AppearanceMode.self, forKey: .mode) ?? .auto
        schemeId = try container.decodeIfPresent(String.self, forKey: .schemeId) ?? SchemePresets.defaultId
        custom = try container.decodeIfPresent(ColorScheme.self, forKey: .custom)
    }

    public var usesCustom: Bool { schemeId == ColorScheme.customId }

    /// The scheme to render: the chosen preset, or the custom scheme with invalid slots replaced by brass values.
    /// An unknown id, or `custom` without a custom scheme, resolves to brass.
    public var effectiveScheme: ColorScheme {
        if usesCustom, let custom { return custom.sanitized(fallback: SchemePresets.default) }
        return SchemePresets.scheme(id: schemeId) ?? SchemePresets.default
    }

    public func isDark(systemIsDark: Bool) -> Bool {
        mode.isDark(systemIsDark: systemIsDark)
    }
}
