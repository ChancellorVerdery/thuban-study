import AppKit

/// A native menu built from closures, popped up at a point in a view. Used where SwiftUI's `.contextMenu` cannot
/// reach, e.g. a right-click inside a web page (the page reports where, Swift shows the real menu).
@MainActor
enum PopupMenu {
    enum Item {
        case action(String, enabled: Bool = true, handler: () -> Void)
        case submenu(String, [Item])
        case separator
    }

    /// Shows `items` with the menu's top-left corner at `point` (in `view`'s coordinates, top-left origin when the
    /// view is flipped). Returns once the menu closes; the chosen handler has run by then.
    static func show(_ items: [Item], at point: NSPoint, in view: NSView) {
        let menu = build(items)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    static func build(_ items: [Item]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, enabled, handler):
                let target = ClosureTarget(handler)
                let menuItem = NSMenuItem(title: title, action: #selector(ClosureTarget.run), keyEquivalent: "")
                menuItem.target = target
                menuItem.representedObject = target   // the item keeps its target alive
                menuItem.isEnabled = enabled
                menu.addItem(menuItem)
            case let .submenu(title, children):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.submenu = build(children)
                menuItem.isEnabled = !children.isEmpty
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    private final class ClosureTarget: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }
}
