import SwiftUI
import ThubanCore

/// Right pane: tutor header, the transcript page, a "connect" card when there are no credentials, and the composer.
struct TutorPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Bindable var session: ClassSession

    @State private var confirmingClear = false

    private var state: StudyState { session.studyState }

    var body: some View {
        VStack(spacing: 0) {
            header
            ChatWebView(controller: state.chat)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = state.tutorError {
                switch error {
                case .notConnected: connectCard
                case .failed(let message): failureCard(message)
                }
            }
            TutorComposer(session: session)
                .thubanHairline(.top, color: theme.lineColor)
        }
        .background(theme.panelColor)
        .onAppear { wireChat() }
    }

    private func wireChat() {
        let chat = state.chat
        let session = session
        chat.onReady = {
            chat.setTranscript(session.transcript, streamingId: session.studyState.streamingMessageId)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Icon(.tutor, size: 18)
                .foregroundStyle(theme.brassInkColor)
            Text("Tutor")
                .font(ThubanFont.display(16))
                .foregroundStyle(theme.inkColor)
            Chip("Guides, never solves", kind: .accent)
            Spacer(minLength: 4)
            Chip(app.tutorModel.shortName, kind: .neutral)
                .help("Tutor model: \(app.tutorModel.displayName)")
            Button("Clear") { confirmingClear = true }
                .buttonStyle(GhostButtonStyle(height: 28, horizontalPadding: 8))
                .disabled(session.transcript.isEmpty)
                .accessibilityLabel("Clear conversation")
                .popover(isPresented: $confirmingClear, arrowEdge: .bottom) {
                    ConfirmPopover(
                        title: "Clear this conversation?",
                        message: threadDescription,
                        confirmTitle: "Clear"
                    ) {
                        confirmingClear = false
                        Task { await session.clearTranscript() }
                    } cancel: {
                        confirmingClear = false
                    }
                    .environment(\.thubanTheme, theme)
                }
        }
        .padding(.horizontal, 14)
        .frame(height: ThubanMetrics.sectionBarHeight)
        .thubanHairline(.bottom, color: theme.lineColor)
    }

    private var threadDescription: String {
        session.currentQuestion == nil
            ? "The class-level conversation with the tutor will be deleted from this Mac."
            : "The conversation about this question will be deleted from this Mac. Other questions keep theirs."
    }

    // MARK: Cards

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your Claude account")
                .font(ThubanFont.display(15))
                .foregroundStyle(theme.inkColor)
            Text("The tutor runs on your Claude account or an API key. Connect in Settings › Claude account, then send your message again.")
                .font(ThubanFont.body(13))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Settings") { openWindow(id: "settings") }
                    .buttonStyle(PrimaryButtonStyle(height: 30))
                Button("Dismiss") { state.tutorError = nil }
                    .buttonStyle(GhostButtonStyle(height: 30))
            }
        }
        .thubanPanel(padding: 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func failureCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(ThubanFont.small)
                .foregroundStyle(theme.negTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(glyph: .close, label: "Dismiss error", size: 22, iconSize: 12) {
                state.tutorError = nil
            }
        }
        .padding(10)
        .background(theme.negSoftColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - Composer

/// Multi-line composer: Enter sends, Shift+Enter inserts a newline; Send; "Ask for the solution" with confirmation.
struct TutorComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    @State private var confirmingSolution = false
    @FocusState private var editorFocused: Bool

    private var state: StudyState { session.studyState }
    private var canSend: Bool {
        !state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isTutorStreaming
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if state.composerText.isEmpty {
                        Text("Ask the tutor…")
                            .font(ThubanFont.body(14))
                            .foregroundStyle(theme.inkFaintColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $state.composerText)
                        .font(ThubanFont.body(14))
                        .foregroundStyle(theme.inkColor)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(minHeight: 40, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($editorFocused)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            if canSend { send() }
                            return .handled
                        }
                        .accessibilityLabel("Message to the tutor")
                }
                .background(theme.bgColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                        .strokeBorder(editorFocused ? theme.accentColor : theme.line2Color, lineWidth: ThubanMetrics.hairline)
                )

                if session.isTutorStreaming {
                    Button {
                        session.cancelTutor()
                    } label: {
                        Glyph(.close, size: 16)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 36))
                    .accessibilityLabel("Stop the tutor")
                    .help("Stop")
                } else {
                    Button(action: send) {
                        Glyph(.send, size: 16)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 36))
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .help("Send (Enter)")
                }
            }
            HStack(spacing: 8) {
                Button {
                    confirmingSolution = true
                } label: {
                    HStack(spacing: 5) {
                        Glyph(.lock, size: 13)
                        Text("Ask for the solution")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.brassInkColor)
                }
                .buttonStyle(.plain)
                .disabled(session.isTutorStreaming || session.currentInstance == nil)
                .accessibilityLabel("Ask for the complete solution")
                .popover(isPresented: $confirmingSolution, arrowEdge: .top) {
                    ConfirmPopover(
                        title: "Ask for the solution?",
                        message: "The tutor will give the complete solution for this question. Continue?",
                        confirmTitle: "Continue"
                    ) {
                        confirmingSolution = false
                        sendSolutionRequest()
                    } cancel: {
                        confirmingSolution = false
                    }
                    .environment(\.thubanTheme, theme)
                }
                Text("Only on your explicit request")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkFaintColor)
                Spacer()
                Text("Shift+Enter for a new line")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.inkFaintColor)
            }
        }
        .padding(12)
    }

    private func send() {
        let text = state.composerText
        state.composerText = ""
        session.sendToTutor(text, solutionRequested: false)
    }

    private func sendSolutionRequest() {
        var text = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "Please give me the complete solution for this question." }
        state.composerText = ""
        session.sendToTutor(text, solutionRequested: true)
    }
}

// MARK: - Confirm popover

/// A small confirmation card for popovers (design-brief modal chrome at popover scale).
struct ConfirmPopover: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    var message: String
    var confirmTitle: String
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(ThubanFont.display(16))
                .foregroundStyle(theme.inkColor)
            Text(message)
                .font(ThubanFont.body(13))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .buttonStyle(PrimaryButtonStyle(height: 30))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(theme.panelColor)
    }
}
