import SwiftUI
import ThubanCore

// MARK: - Test model

/// Runs one Desmos load in a hidden `GraphWebView` and reports whether the calculator came up.
@MainActor
@Observable
final class DesmosTestModel {
    enum Outcome: Equatable {
        case idle
        case running
        case ready(GraphMode)
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    private(set) var outcome: Outcome = .idle
    /// The controller behind the hidden web view while a test runs; `nil` otherwise.
    private(set) var controller: GraphWebView.Controller?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var run = 0

    static let timeoutSeconds: Double = 20

    func start(desmosKey: String) {
        cancel()
        let trimmed = desmosKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outcome = .failed("Enter an API key first.")
            return
        }
        run += 1
        let thisRun = run
        outcome = .running
        let controller = GraphWebView.Controller(desmosKey: trimmed)
        controller.onReady = { [weak controller] in
            // The page replies to `getState` only once the Desmos calculator exists.
            controller?.getState()
        }
        controller.onState = { [weak self] _, mode in
            guard let self, self.run == thisRun else { return }
            self.finish(.ready(mode))
        }
        controller.onError = { [weak self] message in
            guard let self, self.run == thisRun else { return }
            self.finish(.failed(message))
        }
        self.controller = controller
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled, let self, self.run == thisRun, self.outcome == .running else { return }
            self.finish(.failed("No answer from Desmos after \(Int(Self.timeoutSeconds)) s. Check the key and your connection."))
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        controller = nil
        if outcome == .running { outcome = .idle }
    }

    private func finish(_ result: Outcome) {
        timeout?.cancel()
        timeout = nil
        outcome = result
        controller = nil
    }
}

// MARK: - Pane

/// Grapher pane: the Desmos API key behind the 2D/3D grapher and the calculator, with a live load test.
struct GrapherSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    @State private var draft = ""
    @State private var isRevealed = false
    @State private var test = DesmosTestModel()

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { trimmedDraft != app.desmosKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsGroup("Desmos API key", caption: "The grapher and the scientific calculator load the Desmos API with this key.") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        keyField
                        Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                            .buttonStyle(.thubanGhost)
                            .accessibilityLabel(isRevealed ? "Hide API key" : "Reveal API key")
                        Button("Save") { save() }
                            .buttonStyle(.thubanSecondary)
                            .disabled(!isDirty)
                        Button(test.outcome.isRunning ? "Testing…" : "Test") { test.start(desmosKey: trimmedDraft) }
                            .buttonStyle(.thubanPrimary)
                            .disabled(trimmedDraft.isEmpty || test.outcome.isRunning)
                    }
                    sourceCaption
                    testResult
                }
                .thubanPanel()
            }

            SettingsGroup("Where it is used") {
                VStack(alignment: .leading, spacing: 8) {
                    usageRow(icon: .graph2D, title: "2D grapher", detail: "Desmos GraphingCalculator, keypad off, the app's own toolbar.")
                    usageRow(icon: .graph3D, title: "3D grapher", detail: "Desmos Calculator3D, kept in step with the 2D expression list.")
                    usageRow(icon: .calculator, title: "Calculator", detail: "Desmos ScientificCalculator; falls back to the math engine when unavailable.")
                }
                .thubanPanel()
            }
        }
        .onAppear { draft = app.desmosKey }
        .onChange(of: app.desmosKey) { _, key in
            if !isDirty || draft.isEmpty { draft = key }
        }
        .onDisappear { test.cancel() }
        .background(hiddenTester)
    }

    // MARK: Pieces

    @ViewBuilder
    private var keyField: some View {
        Group {
            if isRevealed {
                TextField("Desmos API key", text: $draft)
            } else {
                SecureField("Desmos API key", text: $draft)
            }
        }
        .thubanField(mono: true)
        .onSubmit { save() }
        .accessibilityLabel("Desmos API key")
    }

    private var sourceCaption: some View {
        let bundled = AppModel.bundledDesmosKey
        let text: String
        if app.desmosKey.isEmpty {
            text = bundled == nil
                ? "No key yet. Get one at desmos.com/api and paste it here; it is stored in the app's local settings."
                : "Empty. Save a key here or leave it blank to use the one bundled in Secrets.plist."
        } else if let bundled, bundled == app.desmosKey {
            text = "Seeded from Secrets.plist (DesmosAPIKey). Saving a different key here overrides it for this Mac."
        } else {
            text = "Stored in the app's local settings on this Mac. Keys from desmos.com/api are free for personal use."
        }
        return Text(text)
            .font(ThubanFont.small)
            .foregroundStyle(theme.inkDimColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var testResult: some View {
        switch test.outcome {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                SettingsNote("Loading the Desmos script with this key…")
            }
        case .ready(let mode):
            HStack(spacing: 8) {
                Glyph(.check, size: 14).foregroundStyle(theme.posTextColor)
                SettingsNote("Desmos loaded and the \(mode.label) calculator answered.", tone: .positive)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Glyph(.close, size: 14).foregroundStyle(theme.negTextColor)
                SettingsNote(message, tone: .negative)
            }
        }
    }

    /// A 1×1, invisible graph page that exists only while a test runs.
    @ViewBuilder
    private var hiddenTester: some View {
        if let controller = test.controller {
            GraphWebView(controller: controller)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func usageRow(icon: IconName, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(icon, size: 16)
                .foregroundStyle(theme.brassInkColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
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

    private func save() {
        guard isDirty else { return }
        app.setDesmosKey(trimmedDraft)
    }
}
