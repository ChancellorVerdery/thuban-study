import Foundation

/// A key in the settings table. Values are JSON-encoded by `SettingsRepository`.
public struct SettingsKey: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible,
                           ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// `ClassID` of the class shown last.
    public static let lastClass: SettingsKey = "lastClass"
    /// `ThemeSelection`.
    public static let theme: SettingsKey = "theme"
    /// `ModelPolicy`.
    public static let modelPolicy: SettingsKey = "modelPolicy"
    /// Desmos API key (String).
    public static let desmosKey: SettingsKey = "desmosKey"
    /// Bool: the tutor may add/remove graph expressions.
    public static let tutorMayEditGraph: SettingsKey = "tutorMayEditGraph"
    /// Main window frame as `[Double]` (x, y, w, h).
    public static let windowFrame: SettingsKey = "windowFrame"
    /// Bool: first-run onboarding completed.
    public static let onboardingDone: SettingsKey = "onboardingDone"
}
