import SwiftUI
import ThubanCore

// MARK: - Editor model

/// State of the custom-scheme editor: the eight slots, the text drafts of their hex fields, and the slot being
/// edited with the hue / lightness / saturation strip.
@MainActor
@Observable
final class CustomSchemeEditorModel {
    typealias Slot = ThubanScheme.Slot

    /// The scheme as it will be saved; every slot always holds a valid `#rrggbb`.
    private(set) var scheme: ThubanScheme
    /// What the hex text fields show (may be invalid while typing; invalid text is not applied).
    private(set) var drafts: [Slot: String] = [:]
    private(set) var selectedSlot: Slot? = .accent
    /// HSL of the selected slot, kept separately so a grey (undefined hue) keeps the hue the user chose.
    private(set) var editingHSL = ColorMath.HSL(h: 0, s: 0, l: 0.5)
    /// The preset whose values were last loaded with "Start from".
    var startFromId: String = SchemePresets.defaultId

    init(initial: ThubanScheme) {
        let sanitized = initial.sanitized().asCustom()
        scheme = sanitized
        for slot in Slot.allCases { drafts[slot] = sanitized[slot] }
        syncEditingHSL()
    }

    // MARK: Derived

    var lightTheme: ResolvedTheme { ThemeResolver.resolve(scheme: scheme, isDark: false) }
    var darkTheme: ResolvedTheme { ThemeResolver.resolve(scheme: scheme, isDark: true) }

    func draft(for slot: Slot) -> String { drafts[slot] ?? scheme[slot] }

    func isValid(_ slot: Slot) -> Bool { ColorMath.isValidHex(draft(for: slot)) }

    var hasInvalidDraft: Bool { Slot.allCases.contains { !isValid($0) } }

    /// Role caption under each slot name.
    static func role(of slot: Slot) -> String {
        switch slot {
        case .accent: return "Buttons, active toggles, curves, brass text"
        case .signal: return "Tutor graph rows, reading progress"
        case .pos: return "Correct answers, mastered"
        case .neg: return "Wrong answers, needs review"
        case .darkBg: return "Page ground in dark mode"
        case .darkPanel: return "Cards and panes in dark mode"
        case .lightBg: return "Page ground in light mode"
        case .lightPanel: return "Cards and panes in light mode"
        }
    }

    // MARK: Editing

    func select(_ slot: Slot) {
        selectedSlot = selectedSlot == slot ? nil : slot
        syncEditingHSL()
    }

    /// Text typed in a hex field. Valid values are applied immediately; invalid ones only mark the field.
    func setDraft(_ text: String, for slot: Slot) {
        drafts[slot] = text
        guard let normalized = try? ColorMath.normalizeHex(text) else { return }
        scheme[slot] = normalized
        if slot == selectedSlot { syncEditingHSL() }
    }

    /// A color picked with the hue bar, the sliders or a suggestion chip: applied and echoed into the field.
    func apply(hex: String, to slot: Slot) {
        guard let normalized = try? ColorMath.normalizeHex(hex) else { return }
        scheme[slot] = normalized
        drafts[slot] = normalized
        if slot == selectedSlot { syncEditingHSL() }
    }

    func setHue(_ hue: Double) {
        editingHSL = ColorMath.HSL(h: hue, s: editingHSL.s, l: editingHSL.l)
        applyEditingHSL()
    }

    func setSaturation(_ saturation: Double) {
        editingHSL = ColorMath.HSL(h: editingHSL.h, s: saturation, l: editingHSL.l)
        applyEditingHSL()
    }

    func setLightness(_ lightness: Double) {
        editingHSL = ColorMath.HSL(h: editingHSL.h, s: editingHSL.s, l: lightness)
        applyEditingHSL()
    }

    private func applyEditingHSL() {
        guard let slot = selectedSlot else { return }
        let hex = ColorMath.hslToHex(editingHSL)
        scheme[slot] = hex
        drafts[slot] = hex
    }

    private func syncEditingHSL() {
        guard let slot = selectedSlot, let hsl = try? ColorMath.hexToHSL(scheme[slot]) else { return }
        editingHSL = hsl
    }

    // MARK: Suggestions

    struct Suggestion: Identifiable, Hashable {
        var label: String
        var hex: String
        var id: String { label }
    }

    /// Three companions for the selected slot: its deep shade, a lighter tint and a cooler variant.
    func suggestions(for slot: Slot) -> [Suggestion] {
        let base = scheme[slot]
        guard let hsl = try? ColorMath.hexToHSL(base) else { return [] }
        let deep = (try? ColorMath.shade(base, 0.72)) ?? base
        let lighter = ColorMath.hslToHex(ColorMath.HSL(h: hsl.h, s: hsl.s, l: min(1, hsl.l + 0.14)))
        let cooler = ColorMath.hslToHex(ColorMath.HSL(h: hsl.h + 24, s: max(0, hsl.s - 0.08), l: hsl.l))
        return [
            Suggestion(label: "Deep", hex: deep),
            Suggestion(label: "Lighter", hex: lighter),
            Suggestion(label: "Cooler", hex: cooler),
        ]
    }

    // MARK: Bulk actions

    /// Highlight, Gain and Loss from the accent's hue family.
    func deriveFromAccent() {
        guard let derived = try? SchemeDeriver.applying(accent: scheme.accent, to: scheme) else { return }
        load(derived)
    }

    func resetToBrass() {
        startFromId = SchemePresets.defaultId
        load(SchemePresets.brass)
    }

    /// Loads a preset's values into the editor.
    func startFrom(presetId: String) {
        guard let preset = SchemePresets.scheme(id: presetId) else { return }
        startFromId = presetId
        load(preset)
    }

    private func load(_ source: ThubanScheme) {
        let custom = source.sanitized().asCustom()
        scheme = custom
        for slot in Slot.allCases { drafts[slot] = custom[slot] }
        syncEditingHSL()
    }
}

// MARK: - Sheet

/// Thuban's own scheme editor: two live previews on the left, the eight slot rows with an editor strip on the right.
struct CustomSchemeSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var model: CustomSchemeEditorModel
    private let onSave: (ThubanScheme) -> Void

    init(initial: ThubanScheme, onSave: @escaping (ThubanScheme) -> Void) {
        _model = State(initialValue: CustomSchemeEditorModel(initial: initial))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom scheme")
                    .font(ThubanFont.display(20))
                    .foregroundStyle(theme.inkColor)
                Text("Eight colors. Thuban derives the rest — text tones, hairlines and soft chips — for light and dark.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }

            HStack(alignment: .top, spacing: 20) {
                SchemePreviewColumn(model: model)
                    .frame(width: 300)
                SlotEditorColumn(model: model)
                    .frame(maxWidth: .infinity)
            }

            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)

            HStack(spacing: 10) {
                Text("Applies to every class tab.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.thubanSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save scheme") {
                    onSave(model.scheme)
                    dismiss()
                }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.hasInvalidDraft)
            }
        }
        .padding(24)
        .frame(width: 820)
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.modalRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.modalRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
        .foregroundStyle(theme.inkColor)
    }
}

// MARK: - Left column: previews + contrast

private struct SchemePreviewColumn: View {
    @Environment(\.thubanTheme) private var theme
    var model: CustomSchemeEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewBlock(title: "Light", resolved: model.lightTheme)
            previewBlock(title: "Dark", resolved: model.darkTheme)
            bulkActions
                .padding(.top, 2)
        }
    }

    /// Derive / Reset / Start from — they rewrite several slots at once, so they sit beside the previews.
    private var bulkActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Derive from accent") { model.deriveFromAccent() }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .help("Set Highlight, Gain and Loss from the accent's hue family")
                Button("Reset to Brass") { model.resetToBrass() }
                    .buttonStyle(GhostButtonStyle(height: 32))
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Start from:")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                Picker("Start from", selection: Binding(
                    get: { model.startFromId },
                    set: { model.startFrom(presetId: $0) }
                )) {
                    ForEach(SchemePresets.all) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
                .accessibilityLabel("Start from preset")
                Spacer(minLength: 0)
            }
        }
    }

    private func previewBlock(title: String, resolved: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MiniStudyCard()
                .environment(\.thubanTheme, resolved)
            ContrastReadout(title: title, resolved: resolved)
        }
    }
}

/// A miniature study card drawn entirely with the resolved theme in its environment.
struct MiniStudyCard: View {
    @Environment(\.thubanTheme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Question 7 of 24")
                    .font(.system(size: 11))
                    .foregroundStyle(t.inkDimColor)
                Spacer()
                Chip("Regenerated", kind: .accent)
            }
            Text("Find fₓ(1, 2) for f(x, y) = x²y + 3xy³ − 2y.")
                .font(ThubanFont.display(13, weight: .medium))
                .foregroundStyle(t.inkColor)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("28")
                    .font(ThubanFont.mono(12))
                    .foregroundStyle(t.inkColor)
                Spacer()
                Glyph(.check, size: 12)
                    .foregroundStyle(t.posTextColor)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(t.panelColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.accentColor, lineWidth: 1))
            HStack(spacing: 6) {
                Button("Check answers") {}
                    .buttonStyle(PrimaryButtonStyle(height: 26))
                Button("Hint") {}
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                Spacer()
                Chip("Mastered", kind: .pos)
            }
            .allowsHitTesting(false)
            HStack(spacing: 8) {
                Text("+12 mastered")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.posTextColor)
                Text("−3 needs review")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.negTextColor)
                Spacer()
                Text("Source: HW 4 · Q3")
                    .font(.system(size: 11))
                    .foregroundStyle(t.brassInkColor)
            }
        }
        .padding(8)
        .background(t.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(t.lineColor, lineWidth: ThubanMetrics.hairline)
        )
        .padding(6)
        .background(t.bgColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(t.lineColor, lineWidth: ThubanMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.isDark ? "Dark preview" : "Light preview")
    }
}

/// One-row contrast readout for a resolved theme: ink, brass text and on-accent text (WCAG 4.5:1).
struct ContrastReadout: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    var resolved: ResolvedTheme

    private struct Check: Identifiable {
        var label: String
        var ratio: Double
        var target: Double
        var id: String { label }
        var passes: Bool { ratio >= target }
    }

    private var checks: [Check] {
        [
            Check(label: "Ink", ratio: ratio(resolved.ink, resolved.bg), target: ThemeResolver.textTarget),
            Check(label: "Brass text", ratio: ratio(resolved.accentText, resolved.bg), target: ThemeResolver.textTarget),
            Check(label: "On accent", ratio: ratio(resolved.onAccent, resolved.accent), target: ThemeResolver.textTarget),
        ]
    }

    private func ratio(_ a: String, _ b: String) -> Double {
        (try? ColorMath.contrast(a, b)) ?? 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            ForEach(checks) { check in
                HStack(spacing: 4) {
                    Glyph(check.passes ? .check : .close, size: 11)
                        .foregroundStyle(check.passes ? theme.posTextColor : theme.negTextColor)
                    Text(check.label)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.inkDimColor)
                    Text(String(format: "%.1f", check.ratio))
                        .font(ThubanFont.mono(11))
                        .foregroundStyle(check.passes ? theme.posTextColor : theme.negTextColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.label): \(String(format: "%.1f", check.ratio)) to 1, \(check.passes ? "passes" : "fails")")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Right column: slot rows

private struct SlotEditorColumn: View {
    @Environment(\.thubanTheme) private var theme
    var model: CustomSchemeEditorModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ThubanScheme.Slot.allCases.enumerated()), id: \.element) { index, slot in
                SlotRow(model: model, slot: slot)
                if model.selectedSlot == slot {
                    SlotEditorStrip(model: model, slot: slot)
                }
                if index < ThubanScheme.Slot.allCases.count - 1 {
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                }
            }
        }
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
    }
}

/// Swatch · name + role · hex field. Click the row to expand its editor strip.
private struct SlotRow: View {
    @Environment(\.thubanTheme) private var theme
    var model: CustomSchemeEditorModel
    var slot: ThubanScheme.Slot

    private var isSelected: Bool { model.selectedSlot == slot }
    private var isValid: Bool { model.isValid(slot) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.select(slot)
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hex: model.scheme[slot]))
                        .frame(width: 24, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.label)
                            .font(ThubanFont.body(14, weight: .semibold))
                            .foregroundStyle(isSelected ? theme.brassInkColor : theme.inkColor)
                        Text(CustomSchemeEditorModel.role(of: slot))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.inkDimColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Glyph(isSelected ? .chevronDown : .chevronRight, size: 14)
                        .foregroundStyle(theme.inkFaintColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(slot.label), \(isSelected ? "collapse editor" : "expand editor")")

            TextField("#rrggbb", text: Binding(
                get: { model.draft(for: slot) },
                set: { model.setDraft($0, for: slot) }
            ))
            .thubanField(invalid: !isValid, mono: true, height: 30)
            .frame(width: 100)
            .accessibilityLabel("\(slot.label) hex value")
            .accessibilityValue(isValid ? model.draft(for: slot) : "invalid")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isSelected ? theme.panel2Color : .clear)
    }
}

/// Hue bar + lightness / saturation sliders + three suggested chips for the selected slot.
private struct SlotEditorStrip: View {
    @Environment(\.thubanTheme) private var theme
    var model: CustomSchemeEditorModel
    var slot: ThubanScheme.Slot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HueBar(hue: Binding(get: { model.editingHSL.h }, set: { model.setHue($0) }))
                .frame(height: 16)
            HStack(spacing: 14) {
                labeledSlider("Lightness", value: Binding(get: { model.editingHSL.l }, set: { model.setLightness($0) }))
                labeledSlider("Saturation", value: Binding(get: { model.editingHSL.s }, set: { model.setSaturation($0) }))
            }
            HStack(spacing: 8) {
                Text("Suggested")
                    .font(ThubanFont.micro)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(theme.inkDimColor)
                ForEach(model.suggestions(for: slot)) { suggestion in
                    Button {
                        model.apply(hex: suggestion.hex, to: slot)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: suggestion.hex))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline))
                            Text(suggestion.label)
                        }
                        .thubanChip(kind: .neutral)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(suggestion.label.lowercased()) variant \(suggestion.hex)")
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel2Color)
    }

    private func labeledSlider(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkDimColor)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(ThubanFont.mono(11))
                    .foregroundStyle(theme.inkFaintColor)
            }
            Slider(value: value, in: 0...1)
                .tint(theme.accentColor)
                .controlSize(.small)
                .accessibilityLabel(label)
        }
    }
}

/// A horizontal gradient of twelve hue stops with a draggable marker.
struct HueBar: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var hue: Double

    private var stops: [Color] {
        (0...12).map { Color(hex: ColorMath.hslToHex(ColorMath.HSL(h: Double($0) * 30, s: 0.9, l: 0.55))) }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let x = CGFloat(hue / 360) * width
            ZStack(alignment: .leading) {
                LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline))
                Circle()
                    .fill(Color(hex: ColorMath.hslToHex(ColorMath.HSL(h: hue, s: 0.9, l: 0.55))))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(theme.panelColor, lineWidth: 2))
                    .overlay(Circle().strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline))
                    .offset(x: min(max(0, x - 9), width - 18))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(max(0, drag.location.x / width), 1)
                        hue = Double(fraction) * 360
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int(hue.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: hue = min(360, hue + 10)
            case .decrement: hue = max(0, hue - 10)
            @unknown default: break
            }
        }
    }
}
