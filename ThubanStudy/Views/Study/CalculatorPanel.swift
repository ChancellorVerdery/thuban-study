import SwiftUI
import ThubanCore

/// Floating 360×440 calculator over the study area: draggable by its header, closable; "copy to answer" inserts
/// into the focused form field and fallback evaluations go through the MathEngine.
struct CalculatorPanel: View {
    static let size = CGSize(width: 360, height: 440)

    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    @State private var controller: CalculatorWebView.Controller?
    @State private var dragStart: CGSize?

    private var state: StudyState { session.studyState }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let controller {
                CalculatorWebView(controller: controller)
            } else {
                theme.panel2Color
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .shadow(color: theme.inkColor.opacity(theme.isDark ? 0.5 : 0.12), radius: 18, y: 8)
        .offset(state.calculatorOffset)
        .onAppear { attach() }
        .onChange(of: app.desmosKey) { _, key in
            controller?.configure(desmosKey: key, forceFallback: key.isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calculator")
    }

    private func attach() {
        let controller = state.calculatorController(desmosKey: app.desmosKey)
        let engine = app.engine
        let form = state.form
        controller.onEvaluate = { [weak controller] id, latex in
            Task {
                do {
                    let result = try await engine.evaluate(latex)
                    controller?.sendResult(id: id, latex: result)
                } catch {
                    controller?.sendResult(id: id, error: error.localizedDescription)
                }
            }
        }
        controller.onCopyToAnswer = { latex in
            form.insert(latex: latex)
        }
        controller.onError = { message in
            ClassSession.logger.error("calculator: \(message, privacy: .public)")
        }
        self.controller = controller
    }

    private var header: some View {
        HStack(spacing: 8) {
            Icon(.calculator, size: 16)
                .foregroundStyle(theme.brassInkColor)
            Text("Calculator")
                .font(ThubanFont.display(14))
                .foregroundStyle(theme.inkColor)
            Spacer()
            Glyph(.dragHandle, size: 14)
                .foregroundStyle(theme.inkFaintColor)
            IconButton(glyph: .close, label: "Close calculator", size: 26, iconSize: 13) {
                session.showCalculator = false
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
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
