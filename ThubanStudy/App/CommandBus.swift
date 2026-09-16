import Foundation
import Observation

/// Menu / keyboard commands. Routed through `AppModel.perform(_:)`; screens can take over a command by
/// registering a handler on `AppModel.commands` (e.g. StudyView registers `.checkAnswers`).
enum AppCommand: String, CaseIterable, Hashable, Sendable {
    case newClass          // ⌘N
    case importDocuments   // ⌘I
    case toggleGraph       // ⌘G
    case toggleCalculator  // ⌘K
    case toggleKeyboard    // ⌘⇧K
    case checkAnswers      // ⌘⏎
    case nextQuestion      // ⌘→
    case regenerate
    case showHint
    case openSettings      // ⌘,
}

/// A tiny registry of command handlers. The most recently registered handler for a command wins; unregister when
/// the owning view disappears.
@MainActor
@Observable
final class CommandBus {
    @ObservationIgnored private var handlers: [AppCommand: [(token: UUID, handler: () -> Void)]] = [:]
    /// Bumps whenever a command is performed (views can observe it to react to commands without a handler).
    private(set) var lastPerformed: (command: AppCommand, tick: Int)?

    @discardableResult
    func register(_ command: AppCommand, _ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        handlers[command, default: []].append((token, handler))
        return token
    }

    func unregister(_ token: UUID) {
        for key in handlers.keys {
            handlers[key]?.removeAll { $0.token == token }
        }
    }

    func hasHandler(for command: AppCommand) -> Bool {
        !(handlers[command] ?? []).isEmpty
    }

    /// Runs the latest handler; returns false when nobody handles the command.
    @discardableResult
    func perform(_ command: AppCommand) -> Bool {
        lastPerformed = (command, (lastPerformed?.tick ?? 0) + 1)
        guard let entry = handlers[command]?.last else { return false }
        entry.handler()
        return true
    }
}
