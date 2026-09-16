import SwiftUI

/// One segment of a `SegmentedPicker`.
struct SegmentOption<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var icon: IconName?
    var id: Value { value }

    init(_ value: Value, _ label: String, icon: IconName? = nil) {
        self.value = value
        self.label = label
        self.icon = icon
    }
}

/// Design-brief segmented control: `panel2` track (radius 8, padding 3, gap 2); the active segment is a `panel`
/// card with a 1 px `line` border and `ink` text; the others use `inkDim`.
struct SegmentedPicker<Value: Hashable>: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var selection: Value
    var options: [SegmentOption<Value>]
    var segmentHeight: CGFloat = 30
    var fillsWidth: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let active = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 6) {
                        if let icon = option.icon { Icon(icon, size: 16) }
                        Text(option.label)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? theme.inkColor : theme.inkDimColor)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: segmentHeight)
                    .background(active ? theme.panelColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(active ? theme.lineColor : .clear, lineWidth: ThubanMetrics.hairline)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
    }
}
