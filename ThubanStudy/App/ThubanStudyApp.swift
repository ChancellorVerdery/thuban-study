import SwiftUI
import ThubanCore

@main
struct ThubanStudyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        // Must run before anything touches NSApplication (see SharedTheme): an icon-only launch exits here.
        SharedTheme.refreshIconAndExitIfRequested { AppIconRenderer.render(theme: $0) }
        SmokeHarness.exitIfPointedAtLiveData()   // before the model opens the store or the credentials
        SmokeHarness.installProxyTrapIfRequested()   // before any web view exists
        _appModel = State(initialValue: AppModel())
        AppZoom.shared.installShortcuts()
    }

    var body: some Scene {
        WindowGroup("Thuban Study") {
            ShellView()
                .environment(appModel)
                .frame(minWidth: 1100, minHeight: 700)
                .task {
                    appDelegate.appModel = appModel
                    await appModel.load()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            ZoomCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Class") { appModel.perform(.newClass) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import…") { appModel.perform(.importDocuments) }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommandButton()
                    .environment(appModel)
            }
            CommandMenu("Study") {
                let study = appModel.studySession
                Button("Toggle Graph") { appModel.perform(.toggleGraph) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(study == nil)
                Button("Toggle Calculator") { appModel.perform(.toggleCalculator) }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(study == nil)
                Button("Toggle Keyboard") { appModel.perform(.toggleKeyboard) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(study == nil)
                Button("Toggle Equations") { appModel.perform(.toggleEquations) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(study == nil)
                Divider()
                Button("Check Answers") { appModel.perform(.checkAnswers) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(study?.currentInstance == nil)
                Button("Regenerate Numbers") { appModel.perform(.regenerate) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(study?.canRegenerate != true)
                Button("Next Question") { appModel.perform(.nextQuestion) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(study == nil)
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(appModel)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 640)
    }
}

/// "Settings… ⌘," — lives in the App menu; opens the Settings window scene.
private struct SettingsCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}

/// Quitting waits (briefly) for every class's state to be saved, so the next launch opens where this one left off.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    /// A `--refresh-icon` launch stamps the themed icon on the bundle and exits before any window appears.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
        }
    }

    /// Quitting writes every class's latest state before the process exits (at most 2 s). A quit is never held
    /// back or cancelled: the states are also saved as they change, so this only catches the last half second.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { appModel?.saveAllClassStatesBeforeExit() }
    }
}

extension SharedTheme {
    /// This process was launched with `--refresh-icon` (by another Thuban app): it only draws the icon and exits.
    nonisolated static var isRefreshLaunch: Bool { CommandLine.arguments.contains("--refresh-icon") }
}
