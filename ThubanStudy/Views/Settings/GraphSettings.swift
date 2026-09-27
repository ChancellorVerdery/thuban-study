import SwiftUI
import ThubanCore

/// Graph pane: what the tutor may do with the graph, how the graph paper is drawn, and what draws it (the Thuban
/// Graph engine, bundled with the app and fully offline; nothing to configure).
struct GraphSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 28.z) {
            SettingsGroup("Graph", caption: "The graph pane beside a question, in 2D or 3D, and the floating calculator.") {
                VStack(spacing: 0.z) {
                    SettingsRow("Tutor may open and edit the graph", detail: "Lets the tutor show the graph and add or remove curves while explaining. Its rows are drawn in the scheme's highlight color.") {
                        ThubanSwitch(label: "Tutor may open and edit the graph", isOn: Binding(
                            get: { app.tutorMayEditGraph },
                            set: { app.setTutorMayEditGraph($0) }
                        ))
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    SettingsRow("Reverse contrast graph paper", detail: "Draws the graph paper in the opposite mode: a dark graph in light mode, a light graph in dark mode.") {
                        ThubanSwitch(label: "Reverse contrast graph paper", isOn: Binding(
                            get: { app.graphReverseContrast },
                            set: { app.setGraphReverseContrast($0) }
                        ))
                    }
                }
                .thubanPanel(padding: 16)
                .padding(.top, 2.z)
            }

            SettingsGroup("Engine", caption: "Everything is drawn and computed on this Mac by the Thuban Graph engine. No key, no network.") {
                VStack(alignment: .leading, spacing: 8.z) {
                    usageRow(icon: .graph2D, title: "2D graph", detail: "Functions, relations, points, lists, parametric curves and sliders, with the expression list beside the graph.")
                    usageRow(icon: .graph3D, title: "3D graph", detail: "Surfaces, implicit surfaces, space curves and vectors. It keeps its own rows and camera; switching modes loses nothing.")
                    usageRow(icon: .calculator, title: "Calculator", detail: "Scientific calculator with exact results; Insert puts a result into the answer you are typing.")
                }
                .thubanPanel()
            }
        }
    }

    private func usageRow(icon: IconName, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10.z) {
            Icon(icon, size: 16)
                .foregroundStyle(theme.brassInkColor)
                .padding(.top, 2.z)
            VStack(alignment: .leading, spacing: 2.z) {
                Text(title)
                    .font(ThubanFont.body(14, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                Text(detail)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
