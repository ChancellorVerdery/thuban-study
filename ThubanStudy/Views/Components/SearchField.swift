import SwiftUI

/// Search field in the app's control chrome: search glyph, placeholder, clear button; Escape clears and leaves.
struct SearchField: View {
    @Environment(\.thubanTheme) private var theme
    var placeholder: String
    var label: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var height: CGFloat = ThubanMetrics.buttonHeight

    var body: some View {
        HStack(spacing: 8.z) {
            Glyph(.search, size: 15)
                .foregroundStyle(theme.inkFaintColor)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkColor)
                .focused(focused)
                .onExitCommand { text = ""; focused.wrappedValue = false }
                .accessibilityLabel(label)
            if !text.isEmpty {
                IconButton(glyph: .close, label: "Clear search", size: 22, iconSize: 12) { text = "" }
            }
        }
        .padding(.horizontal, 10.z)
        .frame(height: height)
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                .strokeBorder(focused.wrappedValue ? theme.accentColor : theme.line2Color, lineWidth: ThubanMetrics.hairline)
        )
    }
}
