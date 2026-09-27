import Foundation

/// The graph pane's mode. Raw values are the ones Study has always saved in `classState.<id>.graphMode` and the
/// tutor's `show_graph {mode}` takes ("2d" | "3d"); they equal Thuban Graph's `GraphMode` raw values.
public enum StudyGraphMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case twoD = "2d"
    case threeD = "3d"

    public var id: String { rawValue }
    public var label: String { self == .twoD ? "2D" : "3D" }
}

/// One expression row as the rest of Study sees it (the tutor context, `get_student_work`, smoke checks): a
/// read-only projection of the graph sessions, which are the only source of truth.
public struct StudyGraphRow: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var latex: String
    public var mode: StudyGraphMode
    /// The tutor added (or last replaced) this row.
    public var fromTutor: Bool
    public var hidden: Bool

    public init(id: String, latex: String, mode: StudyGraphMode, fromTutor: Bool, hidden: Bool) {
        self.id = id
        self.latex = latex
        self.mode = mode
        self.fromTutor = fromTutor
        self.hidden = hidden
    }
}
