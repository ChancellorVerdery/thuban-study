import AppKit
import ThubanCore

/// One colour scheme for every Thuban app, and app icons that follow it.
///
/// Contract (identical in every Thuban Mac app — keep this file in sync across repos):
/// - The chosen `ThemeSelection` (mode, scheme id, custom scheme) lives in
///   `~/Library/Application Support/Thuban/theme.json` (plain `JSONEncoder` output of `ThemeSelection`).
/// - Changing the scheme in any app calls `publish`: the file is written and the distributed notification
///   `com.thuban.theme.changed` is posted; running apps reload the file and apply it.
/// - Every app stamps its themed icon onto its own bundle (`NSWorkspace.setIcon`) so Finder, the Dock and Launchpad
///   show the scheme even while the app is closed. Apps that are not running are refreshed by launching their
///   executable with `--refresh-icon` (they draw the icon and exit without UI). Only bundles whose Info.plist has
///   `ThubanSharedTheme = YES` are launched that way, so older builds never open unexpectedly.
@MainActor
enum SharedTheme {
    static let notification = Notification.Name("com.thuban.theme.changed")
    nonisolated static let refreshFlag = "--refresh-icon"
    static let infoKey = "ThubanSharedTheme"

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Thuban", isDirectory: true).appendingPathComponent("theme.json")
    }

    /// Smoke runs and builds inside a repo (`.build/…`) never touch the shared file or any bundle icon.
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        let isSmoke = environment.keys.contains { $0.hasSuffix("_SMOKE") }
        return !isSmoke && !Bundle.main.bundlePath.contains("/.build/")
    }

    // MARK: File

    static func load() -> ThemeSelection? {
        guard isEnabled, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ThemeSelection.self, from: data)
    }

    /// Saves the selection for every Thuban app and tells the running ones; refreshes the icons of the closed ones.
    static func publish(_ selection: ThemeSelection) {
        guard isEnabled, load() != selection else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(selection).write(to: fileURL, options: .atomic)
        } catch {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(notification, object: Bundle.main.bundleIdentifier, userInfo: nil, deliverImmediately: true)
        refreshClosedApps()
    }

    /// Calls `handler` with the shared selection whenever another Thuban app publishes one.
    static func observe(_ handler: @escaping @MainActor (ThemeSelection) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            guard (note.object as? String) != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                if let selection = load() { handler(selection) }
            }
        }
    }

    // MARK: Icons

    private static var lastIconKey: String?

    /// Stamps `image` onto this app's bundle (once per distinct theme key).
    static func setBundleIcon(_ image: NSImage, key: String) {
        guard isEnabled, key != lastIconKey else { return }
        lastIconKey = key
        NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
    }

    /// `--refresh-icon` launch: draw the icon for the shared theme, stamp it and exit. Call as the FIRST statement of
    /// the SwiftUI `App`'s `init()` — before `NSApplication` starts — so the process never registers with the Dock
    /// (registering, even briefly, leaves a blank tile behind).
    nonisolated static func refreshIconAndExitIfRequested(render: (ResolvedTheme) -> NSImage) {
        guard CommandLine.arguments.contains(refreshFlag) else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Thuban/theme.json")
        if let url, let data = try? Data(contentsOf: url), let selection = try? JSONDecoder().decode(ThemeSelection.self, from: data) {
            let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
            let theme = ThemeResolver.resolve(selection, systemIsDark: dark)
            NSWorkspace.shared.setIcon(bitmap(render(theme)), forFile: Bundle.main.bundlePath, options: [])
        }
        exit(0)
    }

    /// Fallback for apps that still call this from `applicationWillFinishLaunching`.
    static func handleRefreshLaunch(render: (ResolvedTheme) -> NSImage) {
        refreshIconAndExitIfRequested(render: render)
    }

    /// Rasterises a drawing-handler image into a 1024 px bitmap (works without a running NSApplication).
    nonisolated static func bitmap(_ image: NSImage, pixels: Int = 1024) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: rep.size)
        output.addRepresentation(rep)
        return output
    }

    /// Other installed Thuban apps that opt in and are not running: launch each with `--refresh-icon`.
    private static func refreshClosedApps() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: applications.path) else { return }
        for name in names where name.hasPrefix("Thuban ") && name.hasSuffix(".app") {
            let url = applications.appendingPathComponent(name)
            guard url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !running.contains(id),
                  (bundle.object(forInfoDictionaryKey: infoKey) as? Bool) == true,
                  let executable = bundle.executableURL else { continue }
            let process = Process()
            process.executableURL = executable
            process.arguments = [refreshFlag]
            try? process.run()
        }
    }
}
