import SwiftUI
import ThubanCore

/// Appearance pane: Mode (Auto / Light / Dark), the 3×3 scheme grid, and a live preview of the resolved theme.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @State private var isEditingCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28.z) {
            SettingsGroup("Mode", caption: modeCaption) {
                SegmentedPicker(
                    selection: Binding(get: { app.themeSelection.mode }, set: { app.setAppearanceMode($0) }),
                    options: AppearanceMode.allCases.map { SegmentOption($0, $0.label) }
                )
            }

            SettingsGroup("Scheme", caption: "Colors only. Every card uses the same Thuban layout; the ninth is yours.") {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 12.z), count: 3)
                LazyVGrid(columns: columns, spacing: 12.z) {
                    ForEach(SchemeCardModel.cards(for: app.themeSelection)) { card in
                        SchemeCard(card: card, isSelected: card.id == app.themeSelection.schemeId) {
                            if card.id == ThubanScheme.customId {
                                isEditingCustom = true
                            } else {
                                app.selectScheme(id: card.id)
                            }
                        }
                    }
                }
            }

            SettingsGroup("Preview", caption: "How the selected scheme reads in \(theme.isDark ? "dark" : "light") mode.") {
                ThemePreviewCard()
            }
        }
        .sheet(isPresented: $isEditingCustom) {
            CustomSchemeSheet(initial: app.themeSelection.custom ?? SchemePresets.default.asCustom()) { scheme in
                app.setCustomScheme(scheme)
            }
            .environment(\.thubanTheme, app.theme)
        }
    }

    private var modeCaption: String {
        switch app.themeSelection.mode {
        case .auto: return "Follows macOS — currently \(app.systemIsDark ? "dark" : "light")."
        case .light: return "Always light, whatever macOS is set to."
        case .dark: return "Always dark, whatever macOS is set to."
        }
    }
}

// MARK: - Scheme card

/// Label + four color dots + a split light|dark ground swatch (each half with a small panel rectangle inside).
/// Selected: accent ring and tint. The default scheme carries a "Default" tag.
struct SchemeCard: View {
    @Environment(\.thubanTheme) private var theme
    var card: SchemeCardModel
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    private var isCustom: Bool { card.id == ThubanScheme.customId }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10.z) {
                HStack(spacing: 8.z) {
                    Text(card.label)
                        .font(.system(size: 14.z, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.brassInkColor : theme.inkColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if card.isDefault {
                        Chip("Default", kind: isSelected ? .accent : .neutral)
                    } else if isCustom && isSelected {
                        Chip("In use", kind: .accent)
                    }
                }
                HStack(spacing: 6.z) {
                    ForEach(Array(card.dots.enumerated()), id: \.offset) { _, hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 14.z, height: 14.z)
                            .overlay(Circle().strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline))
                    }
                    Spacer(minLength: 0)
                    if isCustom {
                        Text("Edit")
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.brassInkColor)
                    }
                }
                SplitGroundSwatch(lightBg: card.lightBg, lightPanel: card.lightPanel, darkBg: card.darkBg, darkPanel: card.darkPanel)
                    .frame(height: 36.z)
            }
            .padding(12.z)
            .background(
                isSelected ? theme.accentTintColor : (hovering ? theme.panel2Color : theme.panelColor),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? theme.accentColor : theme.lineColor, lineWidth: isSelected ? 1.5 : ThubanMetrics.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isCustom ? "Custom scheme, edit" : "\(card.label) scheme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Light ground on the left, dark ground on the right, each with a small panel rectangle inside.
struct SplitGroundSwatch: View {
    @Environment(\.thubanTheme) private var theme
    var lightBg: String
    var lightPanel: String
    var darkBg: String
    var darkPanel: String

    var body: some View {
        HStack(spacing: 0.z) {
            half(bg: lightBg, panel: lightPanel)
            half(bg: darkBg, panel: darkPanel)
        }
        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
        .accessibilityHidden(true)
    }

    private func half(bg: String, panel: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(hex: bg)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: panel))
                .padding(.horizontal, 7.z)
                .padding(.vertical, 6.z)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Preview card

/// A mini class tab bar, primary/secondary buttons, a selected chip, and Gain / Loss lines.
struct ThemePreviewCard: View {
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14.z) {
            HStack(spacing: 4.z) {
                ThubanMarkView(size: 16, color: theme.brassInkColor)
                    .padding(.trailing, 6.z)
                previewTab("Multivariable Calculus", active: true)
                previewTab("Organic Chemistry II", active: false)
                previewTab("US History since 1877", active: false)
                Spacer(minLength: 0)
                Chip("Connected", kind: .pos, dot: true)
            }
            .padding(.horizontal, 12.z)
            .frame(height: 44.z)
            .frame(maxWidth: .infinity)
            .background(theme.panelColor)
            .thubanHairline(.bottom, color: theme.lineColor)

            VStack(alignment: .leading, spacing: 12.z) {
                HStack(spacing: 10.z) {
                    Button("Check answers") {}
                        .buttonStyle(.thubanPrimary)
                    Button("Regenerate numbers") {}
                        .buttonStyle(.thubanSecondary)
                    Spacer(minLength: 0)
                    Chip("Regenerated · seed 4f2a", kind: .accent, icon: .mathEngine)
                }
                .allowsHitTesting(false)
                HStack(spacing: 18.z) {
                    HStack(spacing: 6.z) {
                        Circle().fill(theme.posColor).frame(width: 8.z, height: 8.z)
                        Text("+12 mastered")
                            .font(ThubanFont.body(14, weight: .semibold))
                            .foregroundStyle(theme.posTextColor)
                    }
                    HStack(spacing: 6.z) {
                        Circle().fill(theme.negColor).frame(width: 8.z, height: 8.z)
                        Text("−3 needs review")
                            .font(ThubanFont.body(14, weight: .semibold))
                            .foregroundStyle(theme.negTextColor)
                    }
                    Spacer(minLength: 0)
                    Text("Question 7 of 24")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                }
                ProgressBar(value: 0.5)
            }
            .padding(.horizontal, 16.z)
            .padding(.bottom, 16.z)
        }
        .background(theme.bgColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme preview")
    }

    private func previewTab(_ name: String, active: Bool) -> some View {
        HStack(spacing: 6.z) {
            Icon(.classTab, size: 13)
                .foregroundStyle(active ? theme.brassInkColor : theme.inkDimColor)
            Text(name)
                .lineLimit(1)
        }
        .font(.system(size: 12.z, weight: .semibold))
        .foregroundStyle(active ? theme.inkColor : theme.inkDimColor)
        .padding(.horizontal, 10.z)
        .frame(height: 28.z)
        .background(active ? theme.panel2Color : .clear, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous)
                .strokeBorder(active ? theme.line2Color : .clear, lineWidth: ThubanMetrics.hairline)
        )
    }
}
