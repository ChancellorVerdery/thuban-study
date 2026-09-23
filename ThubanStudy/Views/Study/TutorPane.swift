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
        VStack(spacing: 0.z) {
            header
            ChatWebView(controller: state.chat)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = state.tutorError {
                switch error {
                case .notConnected: connectCard
                case .reconnect(let message): reconnectCard(message)
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
        HStack(spacing: 8.z) {
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
        .padding(.horizontal, 14.z)
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
        VStack(alignment: .leading, spacing: 8.z) {
            Text("Connect your Claude account")
                .font(ThubanFont.display(15))
                .foregroundStyle(theme.inkColor)
            Text("The tutor runs on your Claude account or an API key. Connect in Settings › Claude account, then send your message again.")
                .font(ThubanFont.body(13))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.z) {
                Button("Open Settings") { openWindow(id: "settings") }
                    .buttonStyle(PrimaryButtonStyle(height: 30))
                Button("Dismiss") { state.tutorError = nil }
                    .buttonStyle(GhostButtonStyle(height: 30))
            }
        }
        .thubanPanel(padding: 12)
        .padding(.horizontal, 12.z)
        .padding(.bottom, 10.z)
    }

    /// Credentials exist but stopped working: same shape as the connect card, with the reason and a way to Settings.
    private func reconnectCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8.z) {
            Text("Sign in to Claude again")
                .font(ThubanFont.display(15))
                .foregroundStyle(theme.inkColor)
            Text(message)
                .font(ThubanFont.body(13))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.z) {
                Button("Open Settings") { openWindow(id: "settings") }
                    .buttonStyle(PrimaryButtonStyle(height: 30))
                Button("Dismiss") { state.tutorError = nil }
                    .buttonStyle(GhostButtonStyle(height: 30))
            }
        }
        .thubanPanel(padding: 12)
        .padding(.horizontal, 12.z)
        .padding(.bottom, 10.z)
    }

    private func failureCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8.z) {
            Text(message)
                .font(ThubanFont.small)
                .foregroundStyle(theme.negTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(glyph: .close, label: "Dismiss error", size: 22, iconSize: 12) {
                state.tutorError = nil
            }
        }
        .padding(10.z)
        .background(theme.negSoftColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .padding(.horizontal, 12.z)
        .padding(.bottom, 10.z)
    }
}

// MARK: - Composer

/// Multi-line composer: Enter sends, Shift+Enter inserts a newline; Send; "Ask for the solution" with confirmation.
struct TutorComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    @State private var confirmingSolution = false

    private var state: StudyState { session.studyState }
    private var canSend: Bool {
        !state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isTutorStreaming
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8.z) {
            HStack(alignment: .bottom, spacing: 8.z) {
                // Text with inline, rendered math: "$" (or the √x button) starts a formula.
                HStack(alignment: .bottom, spacing: 0) {
                    ComposerWebView(controller: state.composer)
                        .frame(height: min(max(state.composer.contentHeight, 38), 110) * AppZoom.shared.scale)
                    Button {
                        state.composer.insertMath()
                    } label: {
                        Text("√x")
                            .font(.system(size: 13.z, weight: .semibold, design: .serif))
                            .foregroundStyle(theme.inkDimColor)
                            .frame(width: 28.z, height: 28.z)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4.z)
                    .padding(.bottom, 5.z)
                    .help("Insert math (or type $)")
                    .accessibilityLabel("Insert math")
                }
                .background(theme.bgColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                        .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
                )

                if session.isTutorStreaming {
                    Button {
                        session.cancelTutor()
                    } label: {
                        Glyph(.close, size: 16)
                            .frame(width: 36.z, height: 36.z)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 36))
                    .accessibilityLabel("Stop the tutor")
                    .help("Stop")
                } else {
                    Button(action: send) {
                        Glyph(.send, size: 16)
                            .frame(width: 20.z, height: 20.z)
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 36))
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .help("Send (Enter)")
                }
            }
            footer
        }
        .padding(12.z)
        .onAppear { wireComposer() }
    }

    private func wireComposer() {
        let state = state
        state.composer.onInput = { text in
            if state.composerText != text { state.composerText = text }
        }
        state.composer.onSubmit = { text in
            state.composerText = text
            if canSend { send() }
        }
        state.composer.onReady = {
            // A draft kept across a reload of the page (or typed before it was ready).
            if !state.composerText.isEmpty { state.composer.setText(state.composerText) }
        }
    }

    /// The footer degrades in three steps as the pane narrows (320 pt when the graph shares the window):
    /// link · caption · keyboard hint on one line; the hint goes first; then the caption drops under the link.
    /// Nothing clips mid-glyph: the link keeps its intrinsic size and the captions truncate with an ellipsis.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8.z) {
                solutionLink
                explicitRequestCaption
                Spacer(minLength: 12)
                newlineHint
            }
            HStack(spacing: 8.z) {
                solutionLink
                explicitRequestCaption
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3.z) {
                solutionLink
                explicitRequestCaption
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var solutionLink: some View {
        Button {
            confirmingSolution = true
        } label: {
            HStack(spacing: 5.z) {
                Glyph(.lock, size: 13)
                Text("Ask for the solution")
                    .lineLimit(1)
            }
            .font(.system(size: 12.z, weight: .semibold))
            .foregroundStyle(theme.brassInkColor)
            .fixedSize()
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
    }

    private var explicitRequestCaption: some View {
        Text("Only on your explicit request")
            .font(.system(size: 12.z))
            .foregroundStyle(theme.inkDimColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var newlineHint: some View {
        Text("Shift+Enter for a new line")
            .font(.system(size: 12.z))
            .foregroundStyle(theme.inkDimColor)
            .lineLimit(1)
            .fixedSize()
    }

    private func send() {
        let text = state.composerText
        state.composerText = ""
        state.composer.clear()
        session.sendToTutor(text, solutionRequested: false)
    }

    private func sendSolutionRequest() {
        var text = state.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "Please give me the complete solution for this question." }
        state.composerText = ""
        state.composer.clear()
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
        VStack(alignment: .leading, spacing: 12.z) {
            Text(title)
                .font(ThubanFont.display(16))
                .foregroundStyle(theme.inkColor)
            Text(message)
                .font(ThubanFont.body(13))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.z) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .buttonStyle(PrimaryButtonStyle(height: 30))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16.z)
        .frame(width: 320.z)
        .background(theme.panelColor)
    }
}
