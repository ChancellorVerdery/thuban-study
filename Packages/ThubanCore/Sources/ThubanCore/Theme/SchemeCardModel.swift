import Foundation

/// View data for one card in the Settings scheme grid: label, the four chromatic dots, and the light|dark
/// ground/surface swatches. Raw scheme values, not contrast-nudged (the card previews the scheme itself).
public struct SchemeCardModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    /// `[accent, signal, pos, neg]`.
    public var dots: [String]
    public var lightBg: String
    public var lightPanel: String
    public var darkBg: String
    public var darkPanel: String
    /// True for brass, which the grid tags "Default".
    public var isDefault: Bool

    public init(id: String, label: String, dots: [String], lightBg: String, lightPanel: String,
                darkBg: String, darkPanel: String, isDefault: Bool = false) {
        self.id = id
        self.label = label
        self.dots = dots
        self.lightBg = lightBg
        self.lightPanel = lightPanel
        self.darkBg = darkBg
        self.darkPanel = darkPanel
        self.isDefault = isDefault
    }

    /// Card for a scheme; invalid slots are shown with brass values so a half-edited custom scheme still draws.
    public init(scheme: ColorScheme) {
        let safe = scheme.sanitized(fallback: SchemePresets.default)
        self.init(
            id: scheme.id,
            label: scheme.label,
            dots: [safe.accent, safe.signal, safe.pos, safe.neg],
            lightBg: safe.lightBg,
            lightPanel: safe.lightPanel,
            darkBg: safe.darkBg,
            darkPanel: safe.darkPanel,
            isDefault: scheme.id == SchemePresets.defaultId
        )
    }

    /// Label shown on the ninth card.
    public static let customLabel = "Custom…"

    /// The eight preset cards in grid order.
    public static let presets: [SchemeCardModel] = SchemePresets.all.map(SchemeCardModel.init(scheme:))

    /// The ninth card. Shows the user's custom scheme when there is one, otherwise brass values under the
    /// `custom` id so the card still previews something sensible.
    public static func customCard(_ custom: ColorScheme?) -> SchemeCardModel {
        let base = custom ?? SchemePresets.default.asCustom()
        var card = SchemeCardModel(scheme: base)
        card.id = ColorScheme.customId
        card.label = customLabel
        card.isDefault = false
        return card
    }

    /// All nine cards for a selection: the presets followed by the custom card.
    public static func cards(for selection: ThemeSelection) -> [SchemeCardModel] {
        presets + [customCard(selection.custom)]
    }
}
