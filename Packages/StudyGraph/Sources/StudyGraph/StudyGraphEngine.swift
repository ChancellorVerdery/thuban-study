import Foundation
import Observation
internal import GraphEngine
internal import GraphTypes

/// Study's one Thuban Graph engine (Compute Engine 0.136 + the thuban-*.js layers in their own JSContext), shared by
/// every class's 2D and 3D graph and calculator. Grading stays on ThubanCore's engine (STUDY_INTEGRATION.md §4).
/// The engine loads its scripts lazily on the first analysis; `warmUp()` does that off the main actor ahead of time.
/// Fully offline: everything it runs is bundled.
@MainActor
@Observable
public final class StudyGraphEngine {
    /// Set when the engine's scripts could not be loaded (should never happen offline); graph tools then refuse
    /// with this text and the pane shows it.
    public private(set) var startupError: String?
    @ObservationIgnored let math = MathEngine()
    @ObservationIgnored private var warmTask: Task<Void, Never>?

    public init() {}

    /// Loads the engine's scripts once (idempotent, off the main actor).
    public func warmUp() {
        guard warmTask == nil else { return }
        let math = math
        warmTask = Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try await math.warmUp()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failure { self?.startupError = failure }
        }
    }

    /// Waits for `warmUp()` (tests, smoke).
    public func waitUntilWarm() async {
        warmUp()
        await warmTask?.value
    }

    /// The engine as the graph sessions take it (each `GraphEmbedSession` wraps it in its own client lane).
    var graphEngine: any GraphEngineProtocol { math }

    /// The engine as the calculator takes it (calculators evaluate on the shared engine directly, no lane).
    var calculatorEngine: any CalculatorEngineProtocol { math }
}
