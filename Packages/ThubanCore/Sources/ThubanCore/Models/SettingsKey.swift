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
    /// Bool: credentials were moved out of the login Keychain (or the move was attempted) once.
    public static let credentialsMigrated: SettingsKey = "credentials.migratedFromKeychain"
    /// Bool: the tutor may add/remove graph expressions.
    public static let tutorMayEditGraph: SettingsKey = "tutorMayEditGraph"
    /// Bool: draw the graph paper in the opposite light/dark mode (Settings › Graph). Off by default.
    public static let graphReverseContrast: SettingsKey = "graphReverseContrast"
    /// Main window frame as `[Double]` (x, y, w, h).
    public static let windowFrame: SettingsKey = "windowFrame"
    /// Bool: show figures' written descriptions (captions and spoken labels) while studying. Off by default.
    public static let showFigureDescriptions: SettingsKey = "showFigureDescriptions"
    /// Bool: first-run onboarding completed.
    public static let onboardingDone: SettingsKey = "onboardingDone"
}
