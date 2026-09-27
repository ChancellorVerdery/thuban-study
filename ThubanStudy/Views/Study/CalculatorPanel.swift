import StudyGraph
import SwiftUI
import ThubanCore

/// Floating 360×480 calculator over the study area: draggable by its grip bar, closable. The Scientific calculator
/// of the Thuban Graph engine (offline); "Insert" on a result puts it into the focused answer field. The page has
/// its own "Scientific" title, so the bar above it carries no second title (only the grip and Close).
struct CalculatorPanel: View {
    static let size = CGSize(width: 360, height: 480)

    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    @State private var dragStart: CGSize?

    private var state: StudyState { session.studyState }

    var body: some View {
        let form = state.form
        VStack(spacing: 0.z) {
            header
            StudyCalculatorView(host: session.graphHost, onInsert: { latex in form.insert(latex: latex) })
                .studyGraphTheme(app.theme, zoom: AppZoom.shared.scale)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
        )
        // The shadow belongs to the card's ground only: a shadow on the whole panel flattens it into one layer,
        // and the calculator's web view (a native view) then never reaches the screen.
        .background(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .fill(theme.panelColor)
                .shadow(color: theme.inkColor.opacity(theme.isDark ? 0.5 : 0.12), radius: 18, y: 8)
        )
        .offset(state.calculatorOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calculator")
    }

    private var header: some View {
        HStack(spacing: 8.z) {
            Glyph(.dragHandle, size: 14)
                .foregroundStyle(theme.inkFaintColor)
            Spacer()
            IconButton(glyph: .close, label: "Close calculator", size: 24, iconSize: 12) {
                session.showCalculator = false
            }
        }
        .padding(.leading, 12.z)
        .padding(.trailing, 4.z)
        .frame(height: 28.z)
        .background(theme.panel2Color)
        .thubanHairline(.bottom, color: theme.lineColor)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? state.calculatorOffset
                    dragStart = start
                    state.calculatorOffset = CGSize(width: start.width + value.translation.width,
                                                    height: start.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil }
        )
        .help("Drag to move")
    }
}
