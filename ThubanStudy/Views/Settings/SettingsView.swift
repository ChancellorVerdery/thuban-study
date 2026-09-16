import AppKit
import SwiftUI
import ThubanCore

/// PLACEHOLDER (functional but plain) — the screens phase refines this. Appearance, Claude account, Agents,
/// Grapher, Data & storage.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    enum Pane: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case account = "Claude account"
        case agents = "Agents"
        case grapher = "Grapher"
        case storage = "Data & storage"
        case about = "About"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .appearance

    var body: some View {
        let theme = app.theme
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { item in
                    Button {
                        pane = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: pane == item ? .semibold : .regular))
                            .foregroundStyle(pane == item ? theme.inkColor : theme.inkDimColor)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 32)
                            .background(pane == item ? theme.panel2Color : .clear, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 200)
            .background(theme.panelColor)
            .thubanHairline(.trailing, color: theme.lineColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(pane.rawValue)
                        .font(ThubanFont.display(28))
                        .foregroundStyle(theme.inkColor)
                    switch pane {
                    case .appearance: AppearanceSettings()
                    case .account: AccountSettings()
                    case .agents: AgentSettings()
                    case .grapher: GrapherSettings()
                    case .storage: StorageSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.bgColor)
        }
        .environment(\.thubanTheme, theme)
        .foregroundStyle(theme.inkColor)
        .frame(minWidth: 760, minHeight: 560)
        .background(theme.bgColor)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Mode", caption: app.themeSelection.mode == .auto ? "Follows macOS" : nil) {
                SegmentedPicker(
                    selection: Binding(get: { app.themeSelection.mode }, set: { app.setAppearanceMode($0) }),
                    options: AppearanceMode.allCases.map { SegmentOption($0, $0.label) }
                )
            }
            SettingsGroup("Scheme") {
                let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SchemeCardModel.cards(for: app.themeSelection)) { card in
                        SchemeCard(card: card, selected: card.id == app.themeSelection.schemeId) {
                            app.selectScheme(id: card.id)
                        }
                    }
                }
            }
            SettingsGroup("Preview") {
                HStack(spacing: 10) {
                    Button("Primary") {}.buttonStyle(.thubanPrimary)
                    Button("Secondary") {}.buttonStyle(.thubanSecondary)
                    Chip("Mastered", kind: .pos)
                    Chip("Needs review", kind: .neg)
                    Chip("Learning", kind: .warn)
                    Chip("Signal", kind: .signal)
                }
                .thubanPanel()
            }
        }
    }
}

/// Label + 4 dots (accent/signal/pos/neg) + split light|dark ground swatch.
struct SchemeCard: View {
    @Environment(\.thubanTheme) private var theme
    var card: SchemeCardModel
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(card.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? theme.brassInkColor : theme.inkColor)
                    Spacer()
                    if card.isDefault { Chip("Default", kind: .neutral) }
                }
                HStack(spacing: 6) {
                    ForEach(Array(card.dots.enumerated()), id: \.offset) { _, hex in
                        Circle().fill(Color(hex: hex)).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(theme.lineColor, lineWidth: 1))
                    }
                }
                HStack(spacing: 0) {
                    ZStack {
                        Color(hex: card.lightBg)
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: card.lightPanel)).padding(6)
                    }
                    ZStack {
                        Color(hex: card.darkBg)
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: card.darkPanel)).padding(6)
                    }
                }
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.lineColor, lineWidth: 1))
            }
            .padding(12)
            .background(selected ? theme.accentTintColor : theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                    .strokeBorder(selected ? theme.accentColor : theme.lineColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Claude account

struct AccountSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @State private var apiKey = ""
    @State private var pastedCode = ""
    @State private var flow: OAuthFlow?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Status") {
                HStack(spacing: 10) {
                    switch app.connection {
                    case .notConnected:
                        Chip("Not connected", kind: .neutral, dot: true)
                        Text("Connect your Claude account or paste an API key.")
                            .font(ThubanFont.small).foregroundStyle(theme.inkDimColor)
                    case .apiKey:
                        Chip("Connected · API key", kind: .pos, dot: true)
                    case .oauth(let email, let expiresAt):
                        Chip("Connected", kind: .pos, dot: true)
                        Text(email ?? "Claude account")
                            .font(ThubanFont.body(14))
                        Text("token renews \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(ThubanFont.small).foregroundStyle(theme.inkDimColor)
                    }
                    Spacer()
                    if app.isConnected {
                        Button("Disconnect") { Task { await app.disconnect() } }
                            .buttonStyle(.thubanSecondary)
                    }
                }
                .thubanPanel()
            }
            SettingsGroup("Claude account", caption: "Signs in through claude.ai in your browser, then paste the code shown there.") {
                HStack(spacing: 10) {
                    Button(flow == nil ? "Open browser to sign in" : "Reopen browser") {
                        guard let newFlow = try? OAuthFlow() else {
                            message = "OAuth is misconfigured."
                            return
                        }
                        flow = newFlow
                        Task {
                            let (url, _) = await newFlow.begin()
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.thubanPrimary)
                    TextField("Paste the code here", text: $pastedCode)
                        .textFieldStyle(.roundedBorder)
                    Button(busy ? "Connecting…" : "Connect") { exchange() }
                        .buttonStyle(.thubanSecondary)
                        .disabled(flow == nil || pastedCode.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            SettingsGroup("API key", caption: "Alternatively, use an Anthropic API key.") {
                HStack(spacing: 10) {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save key") {
                        Task {
                            do {
                                try await app.setAPIKey(apiKey)
                                apiKey = ""
                                message = "API key saved."
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.thubanSecondary)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message {
                Text(message).font(ThubanFont.small).foregroundStyle(theme.inkDimColor)
            }
        }
    }

    private func exchange() {
        guard let flow else { return }
        busy = true
        Task {
            do {
                let tokens = try await flow.exchange(pastedCode: pastedCode)
                try await app.setOAuth(tokens)
                pastedCode = ""
                message = "Connected."
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Agents

struct AgentSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("Model", caption: "Sonnet by default. The import agent may escalate itself to Opus for dense material.") {
                SegmentedPicker(
                    selection: Binding(get: { app.modelPolicy.defaultModel }, set: { model in
                        var policy = app.modelPolicy
                        policy.defaultModel = model
                        app.setModelPolicy(policy)
                    }),
                    options: [SegmentOption(.sonnet, "Sonnet"), SegmentOption(.opus, "Opus"), SegmentOption(.haiku, "Haiku")]
                )
            }
            Toggle("The agent may escalate to Opus", isOn: Binding(get: { app.modelPolicy.allowEscalation }, set: { allowed in
                var policy = app.modelPolicy
                policy.allowEscalation = allowed
                app.setModelPolicy(policy)
            }))
            .toggleStyle(.switch)
            Toggle("The tutor may edit the graph", isOn: Binding(get: { app.tutorMayEditGraph }, set: { app.setTutorMayEditGraph($0) }))
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Grapher

struct GrapherSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @State private var key = ""

    var body: some View {
        SettingsGroup("Desmos API key", caption: "Used by the grapher and the calculator. Seeded from Secrets.plist when present.") {
            HStack(spacing: 10) {
                TextField("Desmos API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(ThubanFont.mono(13))
                Button("Save") { app.setDesmosKey(key) }
                    .buttonStyle(.thubanSecondary)
                    .disabled(key == app.desmosKey)
            }
        }
        .onAppear { key = app.desmosKey }
        .onChange(of: app.desmosKey) { _, new in key = new }
    }
}

// MARK: - Data & storage

struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @State private var size: Int64?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("All data is stored on this Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppPaths.baseDirectory.path)
                        .font(ThubanFont.mono(12))
                        .foregroundStyle(theme.inkDimColor)
                        .textSelection(.enabled)
                    if let size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(ThubanFont.small)
                            .foregroundStyle(theme.inkDimColor)
                    }
                    HStack(spacing: 10) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.baseDirectory])
                        }
                        .buttonStyle(.thubanSecondary)
                        Button("Export…") { export() }
                            .buttonStyle(.thubanSecondary)
                    }
                    if let message {
                        Text(message).font(ThubanFont.small).foregroundStyle(theme.inkDimColor)
                    }
                }
                .thubanPanel()
            }
        }
        .task { size = try? await app.store.storageSize() }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Thuban Study export.zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await app.store.exportArchive(to: url)
                    message = "Exported to \(url.path)"
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            ThubanMarkView(size: 40, color: theme.brassInkColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Thuban Study")
                    .font(ThubanFont.display(20))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") · core \(ThubanCoreInfo.version)")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                Text("Named after Thuban, Alpha Draconis, the old pole star.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }
        }
        .thubanPanel()
    }
}

// MARK: - Group chrome

struct SettingsGroup<Content: View>: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    var caption: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ThubanFont.display(18))
                .foregroundStyle(theme.inkColor)
            if let caption {
                Text(caption)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
