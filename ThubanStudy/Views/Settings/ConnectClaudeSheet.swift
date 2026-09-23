import AppKit
import SwiftUI
import ThubanCore

// MARK: - Model

/// Drives the three-step OAuth flow: open claude.ai → paste the authorization code → connected.
@MainActor
@Observable
final class ConnectClaudeModel {
    enum Step: Int, CaseIterable, Identifiable {
        case open, authorize, connected

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .open: return "Open claude.ai"
            case .authorize: return "Authorize"
            case .connected: return "Connected"
            }
        }
    }

    private(set) var step: Step = .open
    private(set) var signInURL: URL?
    var pastedCode = ""
    private(set) var error: String?
    private(set) var isBusy = false
    private(set) var tokens: OAuthTokens?
    @ObservationIgnored private var flow: OAuthFlow?

    /// Scopes Thuban asks for, from the OAuth configuration.
    var scopes: [String] { OAuthConfig.default.scopes.split(separator: " ").map(String.init) }

    var canVerify: Bool {
        flow != nil && !pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    /// Starts a PKCE flow and opens the sign-in page in the default browser.
    func openSignIn() async {
        error = nil
        do {
            let newFlow = try OAuthFlow()
            flow = newFlow
            let (url, _) = await newFlow.begin()
            signInURL = url
            NSWorkspace.shared.open(url)
            step = .authorize
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Exchanges the pasted code for tokens and stores them through the app model.
    func verify(with app: AppModel) async {
        guard let flow, canVerify else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let received = try await flow.exchange(pastedCode: pastedCode)
            try await app.setOAuth(received)
            tokens = received
            step = .connected
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copySignInURL() {
        guard let signInURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(signInURL.absoluteString, forType: .string)
    }
}

// MARK: - Sheet

/// "Connect Claude account": stepper, one card per step, the scopes card, Cancel / Continue.
struct ConnectClaudeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var model = ConnectClaudeModel()

    var body: some View {
        ModalCard(title: "Connect Claude account", width: 560) {
            VStack(alignment: .leading, spacing: 18.z) {
                Text("Sign in on claude.ai, authorize Thuban Study, and paste the code it shows. Nothing else leaves this Mac.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)

                StepperRail(current: model.step)

                switch model.step {
                case .open: openStep
                case .authorize: authorizeStep
                case .connected: connectedStep
                }

                if let error = model.error {
                    SettingsNote(error, tone: .negative)
                }

                ScopesCard(scopes: model.scopes)
            }
        } actions: {
            Button(model.step == .connected ? "Close" : "Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            switch model.step {
            case .open:
                Button("Continue") { Task { await model.openSignIn() } }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.defaultAction)
            case .authorize:
                Button(model.isBusy ? "Verifying…" : "Continue") { Task { await model.verify(with: app) } }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canVerify)
            case .connected:
                Button("Done") { dismiss() }
                    .buttonStyle(.thubanPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Steps

    private var openStep: some View {
        StepCard(number: 1, title: "Open the sign-in page") {
            Text("Your browser opens claude.ai. Sign in, then approve access for Thuban Study.")
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open sign-in page") { Task { await model.openSignIn() } }
                .buttonStyle(.thubanPrimary)
        }
    }

    private var authorizeStep: some View {
        StepCard(number: 2, title: "Paste the authorization code") {
            if let url = model.signInURL {
                VStack(alignment: .leading, spacing: 6.z) {
                    Text("If the browser did not open, use this link:")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                    HStack(spacing: 8.z) {
                        Text(url.absoluteString)
                            .font(ThubanFont.mono(11))
                            .foregroundStyle(theme.inkDimColor)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy") { model.copySignInURL() }
                            .buttonStyle(GhostButtonStyle(height: 26, tinted: true))
                            .accessibilityLabel("Copy sign-in link")
                        Button("Reopen") { NSWorkspace.shared.open(url) }
                            .buttonStyle(GhostButtonStyle(height: 26))
                            .accessibilityLabel("Reopen sign-in page")
                    }
                    .padding(8.z)
                    .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
                }
            }
            LabeledField("Authorization code") {
                HStack(spacing: 10.z) {
                    TextField("Paste the code shown by claude.ai", text: Binding(
                        get: { model.pastedCode },
                        set: { model.pastedCode = $0 }
                    ))
                    .thubanField(mono: true)
                    .onSubmit { Task { await model.verify(with: app) } }
                    .accessibilityLabel("Authorization code")
                    Button(model.isBusy ? "Verifying…" : "Verify") { Task { await model.verify(with: app) } }
                        .buttonStyle(.thubanSecondary)
                        .disabled(!model.canVerify)
                }
            }
            Text("The code may look like code#state — paste it whole.")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkFaintColor)
        }
    }

    private var connectedStep: some View {
        StepCard(number: 3, title: "Connected", done: true) {
            ConnectionStatusCard(
                connection: app.connection,
                accountLabel: app.connectedAccountLabel,
                onConnect: {},
                onDisconnect: {}
            )
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Pieces

/// Three numbered circles joined by hairlines; done steps show a check, the current one is brass.
private struct StepperRail: View {
    @Environment(\.thubanTheme) private var theme
    var current: ConnectClaudeModel.Step

    var body: some View {
        HStack(spacing: 0.z) {
            ForEach(ConnectClaudeModel.Step.allCases) { step in
                let state = state(of: step)
                HStack(spacing: 8.z) {
                    ZStack {
                        Circle()
                            .fill(state == .pending ? theme.panel2Color : (state == .done ? theme.posSoftColor : theme.accentTintColor))
                            .frame(width: 26.z, height: 26.z)
                            .overlay(Circle().strokeBorder(state == .current ? theme.accentColor : theme.lineColor, lineWidth: ThubanMetrics.hairline))
                        if state == .done {
                            Glyph(.check, size: 13).foregroundStyle(theme.posTextColor)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(ThubanFont.display(13))
                                .foregroundStyle(state == .current ? theme.brassInkColor : theme.inkDimColor)
                        }
                    }
                    Text(step.label)
                        .font(.system(size: 13.z, weight: state == .current ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? theme.inkDimColor : theme.inkColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(step.rawValue + 1), \(step.label), \(state.label)")
                if step != ConnectClaudeModel.Step.allCases.last {
                    Rectangle()
                        .fill(state == .done ? theme.accentColor : theme.lineColor)
                        .frame(height: ThubanMetrics.hairline)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10.z)
                }
            }
        }
    }

    private enum StepState { case done, current, pending
        var label: String {
            switch self {
            case .done: return "done"
            case .current: return "current"
            case .pending: return "not started"
            }
        }
    }

    private func state(of step: ConnectClaudeModel.Step) -> StepState {
        if step.rawValue < current.rawValue || current == .connected { return .done }
        return step == current ? .current : .pending
    }
}

/// A step's content in a panel with its number and title.
private struct StepCard<Content: View>: View {
    @Environment(\.thubanTheme) private var theme
    var number: Int
    var title: String
    var done = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12.z) {
            HStack(spacing: 8.z) {
                Text("Step \(number)")
                    .font(ThubanFont.micro)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(theme.brassInkColor)
                Text(title)
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
                if done { Chip("Done", kind: .pos) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .thubanPanel()
    }
}

/// What Thuban asks the account for.
private struct ScopesCard: View {
    @Environment(\.thubanTheme) private var theme
    var scopes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8.z) {
            Text("Scopes")
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            ForEach(scopes, id: \.self) { scope in
                HStack(alignment: .top, spacing: 10.z) {
                    Text(scope)
                        .font(ThubanFont.mono(12))
                        .foregroundStyle(theme.inkColor)
                        .frame(width: 150.z, alignment: .leading)
                    Text(Self.explanation(for: scope))
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14.z)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel2Color, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
    }

    private static func explanation(for scope: String) -> String {
        switch scope {
        case "user:inference": return "Run the tutor and the import agent on your account."
        case "user:profile": return "Show which account is connected."
        case "org:create_api_key": return "Requested by the standard sign-in; Thuban never creates keys."
        default: return "Part of the standard Claude sign-in."
        }
    }
}
