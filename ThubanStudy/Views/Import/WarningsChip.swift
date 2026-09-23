import SwiftUI
import ThubanCore

/// "3 warnings" chip that opens a popover listing what the import could not do as well as it wanted (a chunk
/// that failed, images left out, templates the engine rejected …). Nothing when there are no warnings.
struct WarningsChip: View {
    @Environment(\.thubanTheme) private var theme
    var warnings: [String]
    /// Named in the popover title ("Warnings · hw4.pdf").
    var filename: String

    @State private var isPresented = false

    var body: some View {
        if !warnings.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Chip("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", kind: .warn)
            }
            .buttonStyle(.plain)
            .help("Show the warnings")
            .accessibilityLabel("\(warnings.count) import warnings")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10.z) {
                    Text("Warnings · \(filename)")
                        .font(ThubanFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.inkColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8.z) {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                HStack(alignment: .top, spacing: 8.z) {
                                    Circle()
                                        .fill(theme.brassInkColor)
                                        .frame(width: 6.z, height: 6.z)
                                        .padding(.top, 6.z)
                                    Text(warning)
                                        .font(ThubanFont.small)
                                        .foregroundStyle(theme.inkColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.trailing, 4.z)
                    }
                    .frame(maxHeight: 260.z)
                }
                .padding(16.z)
                .frame(width: 420.z)
                .background(theme.panelColor)
            }
        }
    }
}
