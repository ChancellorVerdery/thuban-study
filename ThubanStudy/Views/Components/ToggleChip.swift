import SwiftUI

/// A 32 pt icon + label toggle (Graph / Calculator / Keyboard). ON: `accentTint` fill, brass text, 1 px accent border.
struct ToggleChip: View {
    @Environment(\.thubanTheme) private var theme
    var label: String
    var icon: IconName
    @Binding var isOn: Bool
    var shortcut: KeyboardShortcut?
    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6.z) {
                Icon(icon, size: 16)
                Text(label)
            }
            .font(.system(size: 13.z, weight: .semibold))
            .foregroundStyle(isOn ? theme.brassInkColor : theme.inkDimColor)
            .padding(.horizontal, 10.z)
            .frame(height: 32.z)
            .background(
                isOn ? theme.accentTintColor : (hovering ? theme.panel2Color : .clear),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(isOn ? theme.accentColor : .clear, lineWidth: ThubanMetrics.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .help(label)
    }
}
