import SwiftUI
import ThubanCore

/// Agents pane: tutor model, import escalation, pinned import model, and whether the tutor may edit the graph.
struct AgentsSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    private var policy: Binding<ModelPolicy> {
        Binding(get: { app.modelPolicy }, set: { app.setModelPolicy($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28.z) {
            SettingsGroup("Models", caption: "Sonnet by default. The import agent may escalate itself to Opus for dense material (proofs, multivariable calculus, organic mechanisms).") {
                VStack(spacing: 0.z) {
                    SettingsRow("Tutor model", detail: "The model beside you while you work questions.") {
                        Picker("Tutor model", selection: policy.defaultModel) {
                            Text("Sonnet").tag(ClaudeModel.sonnet)
                            Text("Opus").tag(ClaudeModel.opus)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140.z)
                        .accessibilityLabel("Tutor model")
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    SettingsRow("Import agent may escalate to Opus", detail: "When Sonnet judges a chunk too dense, the chunk is rerun on Opus and marked Escalated.") {
                        ThubanSwitch(label: "Import agent may escalate to Opus", isOn: policy.allowEscalation)
                    }
                    Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                    SettingsRow("Pin import model", detail: "Force one model for every import and skip escalation.") {
                        Picker("Pin import model", selection: pinnedSelection) {
                            Text("None").tag(PinnedChoice.none)
                            Text("Sonnet").tag(PinnedChoice.sonnet)
                            Text("Opus").tag(PinnedChoice.opus)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140.z)
                        .accessibilityLabel("Pin import model")
                    }
                }
                .thubanPanel(padding: 16)
                .padding(.top, 2.z)
                HStack(spacing: 8.z) {
                    Chip("Tutor · \(app.modelPolicy.defaultModel.shortName)", kind: .accent, icon: .tutor)
                    Chip(importSummary, kind: .neutral, icon: .importDocs)
                }
            }

            SettingsGroup("Tutor", caption: "The tutor guides and never solves; these only decide what it may touch.") {
                VStack(spacing: 0.z) {
                    SettingsRow("Tutor may open and edit the graph", detail: "Lets the tutor show the grapher and add or remove curves while explaining. Its edits are marked \"Added by Tutor\".") {
                        ThubanSwitch(label: "Tutor may open and edit the graph", isOn: Binding(
                            get: { app.tutorMayEditGraph },
                            set: { app.setTutorMayEditGraph($0) }
                        ))
                    }
                }
                .thubanPanel(padding: 16)
                .padding(.top, 2.z)
            }
        }
    }

    private enum PinnedChoice: Hashable { case none, sonnet, opus }

    private var pinnedSelection: Binding<PinnedChoice> {
        Binding(
            get: {
                switch app.modelPolicy.pinned {
                case .sonnet: return .sonnet
                case .opus: return .opus
                default: return .none
                }
            },
            set: { choice in
                var updated = app.modelPolicy
                switch choice {
                case .none: updated.pinned = nil
                case .sonnet: updated.pinned = .sonnet
                case .opus: updated.pinned = .opus
                }
                app.setModelPolicy(updated)
            }
        )
    }

    private var importSummary: String {
        if let pinned = app.modelPolicy.pinned { return "Import · pinned to \(pinned.shortName)" }
        return app.modelPolicy.allowEscalation
            ? "Import · \(app.modelPolicy.defaultModel.shortName), may escalate"
            : "Import · \(app.modelPolicy.defaultModel.shortName) only"
    }
}
