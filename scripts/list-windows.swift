// Prints the on-screen windows owned by "Thuban Study" (debug aid; run with `swift scripts/list-windows.swift`).
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionAll]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list")
    exit(1)
}
var found = 0
for window in list where (window[kCGWindowOwnerName as String] as? String)?.contains("Thuban") == true {
    found += 1
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
    print("window '\(name)' bounds=\(bounds) layer=\(layer) onscreen=\(onscreen)")
}
print("\(found) window(s)")
