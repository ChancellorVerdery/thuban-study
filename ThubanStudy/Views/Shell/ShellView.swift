import SwiftUI
import ThubanCore

/// The main window: custom title bar (traffic lights stay visible on the left), section bar, and the selected
/// class's screen — or the Welcome screen when there are no classes.
struct ShellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        let theme = app.theme
        VStack(spacing: 0) {
            TitleBar()
            if let session = app.selectedSession {
                SectionBar(session: session)
                content(for: session)
                    .id(session.classId)
            } else if app.isLoaded {
                WelcomeView()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgColor)
        .environment(\.thubanTheme, theme)
        .ignoresSafeArea()
        .sheet(isPresented: $app.isPresentingNewClass) {
            NewClassSheet()
                .environment(\.thubanTheme, theme)
        }
        .sheet(item: $app.classPendingDelete) { studyClass in
            DeleteClassAlert(studyClass: studyClass)
                .environment(\.thubanTheme, theme)
        }
        .onChange(of: app.settingsRequest) { _, _ in
            openWindow(id: "settings")
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private func content(for session: ClassSession) -> some View {
        switch session.section {
        case .study:
            StudyView(session: session)
        case .questionBank:
            QuestionBankView(session: session)
        case .importDocs:
            ImportView(session: session)
        }
    }
}

// MARK: - Title bar

/// 52 pt: [traffic-light inset] mark + "Thuban Study" | class tabs + "+" | connection chip + Settings.
struct TitleBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: ThubanMetrics.trafficLightInset - 16)
            HStack(spacing: 8) {
                ThubanMarkView(size: 20, color: theme.brassInkColor)
                Text("Thuban Study")
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
            }
            .padding(.trailing, 12)

            ClassTabStrip()

            Spacer(minLength: 8)

            ConnectionChip()
            Button {
                openWindow(id: "settings")
            } label: {
                HStack(spacing: 6) {
                    Icon(.themePalette, size: 16)
                    Text("Settings")
                }
            }
            .buttonStyle(GhostButtonStyle(height: 34))
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .frame(height: ThubanMetrics.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(theme.panelColor)
        .thubanHairline(.bottom, color: theme.lineColor)
        .gesture(WindowDragGesture())
    }
}

/// Connected / Not connected. Clicking opens Settings (Claude account).
struct ConnectionChip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "settings")
        } label: {
            Chip(app.connectionSummary, kind: app.isConnected ? .pos : (app.connection.needsAttention ? .warn : .neutral), dot: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.isConnected ? "Claude account connected. Open Settings" : "Claude account \(app.connectionSummary.lowercased()). Open Settings")
        .help(app.isConnected ? "Claude account connected" : (app.connection.needsAttention ? "Sign in to Claude again in Settings" : "Connect your Claude account in Settings"))
    }
}

// MARK: - Class tabs

struct ClassTabStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @State private var renaming: StudyClass?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(app.classes) { studyClass in
                        ClassTab(studyClass: studyClass, isActive: studyClass.id == app.selectedClassID) {
                            app.selectClass(studyClass.id)
                        }
                        .contextMenu {
                            Button("Rename…") { renaming = studyClass }
                            Divider()
                            Button("Delete…", role: .destructive) { app.classPendingDelete = studyClass }
                        }
                        .draggable(studyClass.id.raw)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, raw != studyClass.id.raw else { return false }
                            Task { await app.moveClass(ClassID(raw: raw), before: studyClass.id) }
                            return true
                        }
                    }
                }
            }
            .scrollClipDisabled()
            IconButton(glyph: .plus, label: "New class", size: 34, iconSize: 16) {
                app.isPresentingNewClass = true
            }
        }
        .sheet(item: $renaming) { studyClass in
            RenameClassSheet(studyClass: studyClass)
                .environment(\.thubanTheme, theme)
        }
    }
}

/// One tab: 34 pt, radius 8, class icon + name. Active: `panel2` fill, `ink` text, 1 px `line2`.
struct ClassTab: View {
    @Environment(\.thubanTheme) private var theme
    var studyClass: StudyClass
    var isActive: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon(.classTab, size: 16)
                    .foregroundStyle(tint)
                Text(studyClass.name)
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isActive ? theme.inkColor : theme.inkDimColor)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                isActive ? theme.panel2Color : (hovering ? theme.panel2Color.opacity(0.6) : .clear),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(isActive ? theme.line2Color : .clear, lineWidth: ThubanMetrics.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .help(studyClass.courseCode.map { "\(studyClass.name) · \($0)" } ?? studyClass.name)
    }

    private var tint: Color {
        if let hex = studyClass.tint, !hex.isEmpty { return Color(hex: hex) }
        return isActive ? theme.brassInkColor : theme.inkDimColor
    }
}

// MARK: - Section bar

/// 44 pt: [Study | Question Bank | Import] … on Study: Graph / Calculator / Keyboard toggles + "Question n of N".
struct SectionBar: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    var body: some View {
        HStack(spacing: 10) {
            SegmentedPicker(selection: $session.section, options: [
                SegmentOption(.study, "Study"),
                SegmentOption(.questionBank, "Question Bank", icon: .questionBank),
                SegmentOption(.importDocs, "Import", icon: .importDocs),
            ])
            Spacer()
            if session.section == .study {
                ToggleChip(label: "Graph", icon: .graph2D, isOn: $session.showGraph)
                ToggleChip(label: "Calculator", icon: .calculator, isOn: $session.showCalculator)
                ToggleChip(label: "Keyboard", icon: .mathKeyboard, isOn: $session.showKeyboard)
                Rectangle()
                    .fill(theme.lineColor)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)
                Text(session.questionCount == 0 ? "No questions yet" : "Question \(session.questionNumber) of \(session.questionCount)")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: ThubanMetrics.sectionBarHeight)
        .frame(maxWidth: .infinity)
        .background(theme.bgColor)
        .thubanHairline(.bottom, color: theme.lineColor)
    }
}

// MARK: - Welcome

/// Shown when there are no classes: connect Claude + create the first class.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    ThubanMarkView(size: 36, color: theme.brassInkColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome to Thuban Study")
                            .font(ThubanFont.display(28))
                            .foregroundStyle(theme.inkColor)
                        Text("Import your course documents, let the agent build a question bank, then work problems beside a tutor that guides instead of answers.")
                            .font(ThubanFont.body(15))
                            .foregroundStyle(theme.inkDimColor)
                    }
                }
                Rectangle().fill(theme.lineColor).frame(height: 1)
                HStack(alignment: .top, spacing: 16) {
                    WelcomeStep(
                        number: "1",
                        title: "Connect Claude",
                        body: app.isConnected ? "Your Claude account is connected." : "The tutor and the import agent run on your Claude account or an API key.",
                        done: app.isConnected
                    ) {
                        // Two Buttons rather than a type-erased style: a ButtonStyle only gets its environment
                        // (theme, isEnabled) when SwiftUI installs it through `.buttonStyle()`.
                        if app.isConnected {
                            Button("Manage account") { openWindow(id: "settings") }
                                .buttonStyle(.thubanSecondary)
                        } else {
                            Button("Connect…") { openWindow(id: "settings") }
                                .buttonStyle(.thubanPrimary)
                        }
                    }
                    WelcomeStep(
                        number: "2",
                        title: "Create your first class",
                        body: "Each class is a tab with its own documents, question bank and tutor transcript.",
                        done: false
                    ) {
                        Button("New class") { app.isPresentingNewClass = true }
                            .buttonStyle(.thubanPrimary)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                if let error = app.startupError {
                    Text(error)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.negTextColor)
                }
            }
            .thubanPanel(padding: 24)
            .frame(maxWidth: 760)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct WelcomeStep<Action: View>: View {
    @Environment(\.thubanTheme) private var theme
    var number: String
    var title: String
    var body_: String
    var done: Bool
    @ViewBuilder var action: () -> Action

    init(number: String, title: String, body: String, done: Bool, @ViewBuilder action: @escaping () -> Action) {
        self.number = number
        self.title = title
        self.body_ = body
        self.done = done
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number)
                    .font(ThubanFont.display(15))
                    .foregroundStyle(done ? theme.posTextColor : theme.brassInkColor)
                    .frame(width: 26, height: 26)
                    .background(done ? theme.posSoftColor : theme.accentTintColor, in: Circle())
                Text(title)
                    .font(ThubanFont.display(18))
                    .foregroundStyle(theme.inkColor)
                if done { Chip("Done", kind: .pos) }
            }
            Text(body_)
                .font(ThubanFont.body(14))
                .foregroundStyle(theme.inkDimColor)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
