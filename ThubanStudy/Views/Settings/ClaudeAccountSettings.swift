import SwiftUI
import ThubanCore

/// Claude account pane: the status card, connect / reconnect / disconnect, and the API key disclosure.
struct ClaudeAccountSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    @State private var isConnecting = false
    @State private var isConfirmingDisconnect = false
    @State private var isShowingAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsGroup("Status") {
                ConnectionStatusCard(
                    connection: app.connection,
                    accountLabel: app.connectedAccountLabel,
                    onConnect: { isConnecting = true },
                    onDisconnect: { isConfirmingDisconnect = true }
                )
            }

            SettingsGroup("API key", caption: "An Anthropic API key works instead of an account. When both are present, the account is used.") {
                APIKeyDisclosure(isExpanded: $isShowingAPIKey)
            }

            SettingsGroup("How sign-in works") {
                VStack(alignment: .leading, spacing: 8) {
                    explainer("Connecting opens claude.ai in your browser. You sign in there, authorize Thuban Study, and paste the code it shows back here.")
                    explainer("Tokens and API keys are kept in the macOS Keychain under com.thuban.study, never in the database or the export archive.")
                    explainer("Access tokens renew themselves a few minutes before they expire. Disconnecting removes them from the Keychain.")
                }
                .thubanPanel()
            }
        }
        .sheet(isPresented: $isConnecting) {
            ConnectClaudeSheet()
                .environment(\.thubanTheme, app.theme)
        }
        .confirmationDialog("Disconnect Claude?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await app.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tutor and the import agent stop working until you connect again. Your classes and question banks stay.")
        }
    }

    private func explainer(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Glyph(.dot, size: 12)
                .foregroundStyle(theme.brassInkColor)
                .padding(.top, 4)
            Text(text)
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Status card

/// Connected (account or API key) or not: icon, headline, chips, expiry caption and the action buttons.
struct ConnectionStatusCard: View {
    @Environment(\.thubanTheme) private var theme
    var connection: ConnectionStatus
    var accountLabel: String
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(ThubanFont.display(18))
                    .foregroundStyle(theme.inkColor)
                HStack(spacing: 8) {
                    switch connection {
                    case .oauth:
                        Chip("Claude account", kind: .pos, dot: true)
                        Chip("Scopes: inference · profile", kind: .neutral)
                    case .apiKey:
                        Chip("API key", kind: .pos, dot: true)
                        Chip("Messages API", kind: .neutral)
                    case .notConnected:
                        Chip("Not connected", kind: .neutral, dot: true)
                    }
                }
                Text(caption)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                switch connection {
                case .notConnected:
                    Button("Connect Claude account", action: onConnect)
                        .buttonStyle(.thubanPrimary)
                case .apiKey:
                    Button("Connect Claude account", action: onConnect)
                        .buttonStyle(.thubanSecondary)
                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.thubanDangerOutline)
                case .oauth:
                    Button("Reconnect", action: onConnect)
                        .buttonStyle(.thubanSecondary)
                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.thubanDangerOutline)
                }
            }
        }
        .thubanPanel(padding: 20)
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(connection.isConnected ? theme.posSoftColor : theme.panel2Color)
                .frame(width: 40, height: 40)
            if connection.isConnected {
                Glyph(.check, size: 20)
                    .foregroundStyle(theme.posTextColor)
            } else {
                Icon(.tutor, size: 20)
                    .foregroundStyle(theme.inkDimColor)
            }
        }
        .accessibilityHidden(true)
    }

    private var headline: String {
        switch connection {
        case .oauth: return "Connected as \(accountLabel)"
        case .apiKey: return "Using an API key"
        case .notConnected: return "Not connected"
        }
    }

    private var caption: String {
        switch connection {
        case .oauth(_, let expiresAt):
            let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
            return expiresAt > Date()
                ? "Access token renews automatically · current one expires \(when)."
                : "Access token expired \(when) · it renews on the next request."
        case .apiKey:
            return "Requests are billed to the key's Anthropic organization."
        case .notConnected:
            return "Connect your Claude account, or paste an API key below."
        }
    }
}

// MARK: - API key disclosure

/// "Use an API key instead" → SecureField + Save, with the storage caption.
struct APIKeyDisclosure: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Binding var isExpanded: Bool
    @State private var apiKey = ""
    @State private var note: (text: String, tone: SettingsNote.Tone)?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Glyph(isExpanded ? .chevronDown : .chevronRight, size: 14)
                        .foregroundStyle(theme.inkFaintColor)
                    Text("Use an API key instead")
                        .font(ThubanFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.inkColor)
                    Spacer()
                    if case .apiKey = app.connection {
                        Chip("Saved", kind: .pos)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide API key field" : "Show API key field")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SecureField("sk-ant-…", text: $apiKey)
                            .thubanField(mono: true)
                            .onSubmit { save() }
                            .accessibilityLabel("API key")
                        Button(isSaving ? "Saving…" : "Save") { save() }
                            .buttonStyle(.thubanSecondary)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    }
                    Text("Create one at console.anthropic.com. The key is stored in the Keychain and only ever sent to api.anthropic.com.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        SettingsNote(note.text, tone: note.tone)
                    }
                }
                .padding(.top, 14)
            }
        }
        .thubanPanel()
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await app.setAPIKey(trimmed)
                apiKey = ""
                note = ("API key saved to the Keychain.", .positive)
            } catch {
                note = (error.localizedDescription, .negative)
            }
            isSaving = false
        }
    }
}
