import AppKit
import Observation
import SwiftUI

/// The app-wide zoom (⌘+ / ⌘− / ⌘0), like a browser's: every font size and layout metric is multiplied by
/// `scale` (`12.z`), so the whole interface grows and reflows rather than being magnified. Views read the scale
/// while computing their bodies, so Observation redraws them when it changes. Persisted across launches.
@MainActor @Observable
final class AppZoom {
    static let shared = AppZoom()

    static let steps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.2, 1.35, 1.5, 1.7]
    private static let defaultsKey = "appZoom"

    private(set) var scale: CGFloat

    private init() {
        // THUBAN_ZOOM (development: smoke screenshots at a zoom) overrides the saved value without replacing it.
        if let forced = ProcessInfo.processInfo.environment["THUBAN_ZOOM"].flatMap(Double.init), forced > 0 {
            scale = CGFloat(forced)
            return
        }
        let stored = UserDefaults.standard.double(forKey: Self.defaultsKey)
        scale = Self.steps.contains(CGFloat(stored)) ? CGFloat(stored) : 1
    }

    var canZoomIn: Bool { scale < Self.steps.last! }
    var canZoomOut: Bool { scale > Self.steps.first! }
    var percent: Int { Int((scale * 100).rounded()) }

    func zoomIn() { set(Self.steps.first { $0 > scale + 0.001 } ?? scale) }
    func zoomOut() { set(Self.steps.last { $0 < scale - 0.001 } ?? scale) }
    func reset() { set(1) }

    private func set(_ value: CGFloat) {
        guard value != scale else { return }
        scale = value
        UserDefaults.standard.set(Double(value), forKey: Self.defaultsKey)
    }

    private var monitor: Any?

    /// ⌘= and ⌘+ (with or without Shift, main keyboard or keypad), ⌘− and ⌘0, whatever has focus. The View
    /// menu shows the same commands; the monitor sees the keys first, so each press acts once.
    func installShortcuts() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "=", "+":
                MainActor.assumeIsolated { AppZoom.shared.zoomIn() }
                return nil
            case "-", "_":
                MainActor.assumeIsolated { AppZoom.shared.zoomOut() }
                return nil
            case "0":
                MainActor.assumeIsolated { AppZoom.shared.reset() }
                return nil
            default:
                return event
            }
        }
    }
}

/// `12.z`: a point size or layout metric at the current app zoom.
extension Int {
    @MainActor var z: CGFloat { CGFloat(self) * AppZoom.shared.scale }
}

extension Double {
    @MainActor var z: CGFloat { CGFloat(self) * AppZoom.shared.scale }
}

extension CGFloat {
    @MainActor var z: CGFloat { self * AppZoom.shared.scale }
}

/// View ▸ Zoom In / Zoom Out / Actual Size.
struct ZoomCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            ZoomMenuItems()
        }
    }
}

private struct ZoomMenuItems: View {
    private var zoom = AppZoom.shared

    var body: some View {
        Divider()
        Button("Actual Size") { zoom.reset() }
            .keyboardShortcut("0", modifiers: .command)
        Button("Zoom In") { zoom.zoomIn() }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!zoom.canZoomIn)
        Button("Zoom Out") { zoom.zoomOut() }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!zoom.canZoomOut)
        Divider()
    }
}
