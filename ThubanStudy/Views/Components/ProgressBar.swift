import SwiftUI

/// A thin accent progress bar on a `panel2` track (radius 3). `value` in 0…1.
struct ProgressBar: View {
    @Environment(\.thubanTheme) private var theme
    var value: Double
    var height: CGFloat = 6
    var tint: Color?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.panel2Color)
                Capsule()
                    .fill(tint ?? theme.accentColor)
                    .frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((max(0, min(1, value)) * 100).rounded())) percent")
    }
}
