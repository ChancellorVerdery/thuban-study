import Foundation
import StudyGraph
import ThubanCore

/// The graph pane's mode ("2d" | "3d", the raw values `classState.<id>` has always saved).
typealias GraphMode = StudyGraphMode

extension ClassSession {
    /// The class's graphs on the Thuban Graph engine (a 2D and a 3D session, the calculator), created on first use
    /// and kept with the study state. Its saved rows (`classGraph.<class id>`) are read when it is created.
    var graphHost: StudyGraphHost {
        let state = studyState
        if let host = state.graph { return host }
        let host = StudyGraphHost(engine: app.graphEngine, mode: graphMode)
        host.onModeChange = { [weak self] mode in
            guard let self, self.graphMode != mode else { return }
            self.graphMode = mode
        }
        host.onShowGraph = { [weak self] shown in
            guard let self, self.showGraph != shown else { return }
            self.showGraph = shown
        }
        state.graph = host
        // Synchronous: the load exists before any tool call or edit, and those wait for it (never replaced by it).
        host.connect(store: store, classId: classId)
        return host
    }

    /// The shown rows of the mode on screen ("On the graph now" in the tutor context, `get_student_work`). Empty
    /// until the class's graph has been opened or used this launch.
    var visibleGraphLatex: [String] {
        studyState.graph?.visibleLatex ?? []
    }

    /// The "Tutor is editing" chip (the tutor changed the graph in the last 5 s).
    var tutorEditedRecently: Bool {
        studyState.graph?.tutorEditedRecently ?? false
    }

    /// Runs a tutor graph tool on the class's graph; nil for a tool that is not a graph tool.
    func handleGraphTool(name: String, input: JSONValue) async -> JSONValue? {
        guard StudyGraphTools.names.contains(name) else { return nil }
        return await StudyGraphTools.execute(name: name, arguments: input, host: graphHost, mayEditGraph: app.tutorMayEditGraph)
    }
}
