import SwiftUI
import ThubanCore

/// The Study screen's quick reference: this class's equation sheet, read-only, beside the question. Searchable,
/// groups fold away; "Edit sheet" jumps to the Equations section.
struct EquationsPane: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession
    @FocusState private var searchFocused: Bool

    private var state: EquationsState { session.equations }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0.z) {
            header
            if state.isLoaded, state.sheet.isEmpty {
                VStack(spacing: 10.z) {
                    Icon(.equations, size: 24)
                        .foregroundStyle(theme.brassInkColor)
                    Text("No equations yet")
                        .font(ThubanFont.display(17))
                        .foregroundStyle(theme.inkColor)
                    Text("Add the equations you want within reach in the Equations section.")
                        .font(ThubanFont.body(13))
                        .foregroundStyle(theme.inkDimColor)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240.z)
                    Button("Open the equation sheet") { session.section = .equations }
                        .buttonStyle(.thubanSecondary)
                }
                .padding(20.z)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SearchField(placeholder: "Search equations", label: "Search equations", text: $state.panelSearch,
                            focused: $searchFocused, height: 30.z)
                    .padding(.horizontal, 12.z)
                    .padding(.vertical, 8.z)
                EquationSheetWebView(controller: state.panelPage)
                    .accessibilityLabel("Equation sheet, read only")
            }
        }
        .background(theme.panelColor)
        .task(id: session.classId) { await session.loadEquationSheet() }
        .onChange(of: state.panelSearch) { _, _ in state.push() }
    }

    /// The title goes first when the pane is narrow; "Edit sheet" and close are never squeezed.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(title: true)
            headerRow(title: false)
        }
        .padding(.horizontal, 12.z)
        .frame(height: ThubanMetrics.sectionBarHeight)
        .frame(maxWidth: .infinity)
        .thubanHairline(.bottom, color: theme.lineColor)
    }

    private func headerRow(title: Bool) -> some View {
        HStack(spacing: 8.z) {
            Icon(.equations, size: 18)
                .foregroundStyle(theme.brassInkColor)
                .accessibilityLabel("Equations")
            if title {
                Text("Equations")
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Button(title ? "Edit" : "Edit sheet") { session.section = .equations }
                .buttonStyle(GhostButtonStyle(height: 28, tinted: true, horizontalPadding: 8))
                .fixedSize()
                .accessibilityLabel("Edit sheet")
                .help("Open the Equations section to add, edit or reorder equations")
            IconButton(glyph: .close, label: "Close equations", size: 28, iconSize: 14) {
                session.showEquations = false
            }
        }
    }
}
