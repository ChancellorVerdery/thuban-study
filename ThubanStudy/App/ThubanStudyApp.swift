import SwiftUI
import ThubanCore

@main
struct ThubanStudyApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Thuban Study") {
            ShellView()
                .environment(appModel)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await appModel.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
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
