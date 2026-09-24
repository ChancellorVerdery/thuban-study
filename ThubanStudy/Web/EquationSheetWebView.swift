import AppKit
import SwiftUI
import ThubanCore

/// A class's equation sheet (`web/equations/sheet.html`): groups under micro eyebrows, entries as MathLive-rendered
/// cards in as many columns as fit. `.sheet` is the editable Equations section; `.panel` the read-only Study panel.
/// The page reports gestures (edit, drag to reorder, right-click, keys); Swift owns the data and shows native menus.
struct EquationSheetWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "equations/sheet.html", bridge: controller.bridge, theme: theme)
    }

    enum Mode: String { case sheet, panel }

    /// A right-click (or "…" button / menu key) on the page. `point` is in page CSS pixels.
    struct MenuRequest {
        enum Kind: String { case entry, group, equation }
        var kind: Kind
        var groupId: EquationGroupID
        var entryId: EquationEntryID?
        var index: Int?
        var point: CGPoint
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        let mode: Mode
        var isPageReady: Bool { bridge.isPageReady }

        var onEdit: ((EquationEntryID) -> Void)?
        var onAddEntry: ((EquationGroupID) -> Void)?
        var onMenu: ((MenuRequest) -> Void)?
        var onMoveEntry: ((EquationEntryID, EquationGroupID, Int) -> Void)?
        var onMoveEntryBy: ((EquationEntryID, Int) -> Void)?
        var onDeleteEntry: ((EquationEntryID) -> Void)?
        var onCopyLatex: ((EquationEntryID, Int?) -> Void)?
        var onToggleGroup: ((EquationGroupID, Bool) -> Void)?

        init(mode: Mode) {
            self.mode = mode
            bridge = WebBridge(name: "equations-\(mode.rawValue)")
            bridge.on("edit") { [weak self] payload in
                guard let id = payload["entryId"]?.stringValue else { return }
                self?.onEdit?(EquationEntryID(raw: id))
            }
            bridge.on("addEntry") { [weak self] payload in
                guard let id = payload["groupId"]?.stringValue else { return }
                self?.onAddEntry?(EquationGroupID(raw: id))
            }
            bridge.on("menu") { [weak self] payload in
                guard let kind = payload["kind"]?.stringValue.flatMap(MenuRequest.Kind.init(rawValue:)),
                      let group = payload["groupId"]?.stringValue else { return }
                let request = MenuRequest(
                    kind: kind,
                    groupId: EquationGroupID(raw: group),
                    entryId: payload["entryId"]?.stringValue.map(EquationEntryID.init(raw:)),
                    index: payload["index"]?.doubleValue.map { Int($0) },
                    point: CGPoint(x: payload["x"]?.doubleValue ?? 0, y: payload["y"]?.doubleValue ?? 0)
                )
                self?.onMenu?(request)
            }
            bridge.on("moveEntry") { [weak self] payload in
                guard let entry = payload["entryId"]?.stringValue, let group = payload["groupId"]?.stringValue,
                      let index = payload["index"]?.doubleValue else { return }
                self?.onMoveEntry?(EquationEntryID(raw: entry), EquationGroupID(raw: group), Int(index))
            }
            bridge.on("moveEntryBy") { [weak self] payload in
                guard let entry = payload["entryId"]?.stringValue, let delta = payload["delta"]?.doubleValue else { return }
                self?.onMoveEntryBy?(EquationEntryID(raw: entry), Int(delta))
            }
            bridge.on("deleteEntry") { [weak self] payload in
                guard let entry = payload["entryId"]?.stringValue else { return }
                self?.onDeleteEntry?(EquationEntryID(raw: entry))
            }
            bridge.on("copyLatex") { [weak self] payload in
                guard let entry = payload["entryId"]?.stringValue else { return }
                self?.onCopyLatex?(EquationEntryID(raw: entry), payload["index"]?.doubleValue.map { Int($0) })
            }
            bridge.on("toggleGroup") { [weak self] payload in
                guard let group = payload["groupId"]?.stringValue else { return }
                self?.onToggleGroup?(EquationGroupID(raw: group), payload["collapsed"]?.boolValue ?? false)
            }
        }

        // MARK: Swift → JS

        /// Shows `sheet` (already filtered). Sticky: a re-created view (section switched, panel toggled) gets the
        /// latest sheet again as soon as its page is ready.
        func load(_ sheet: EquationSheet, collapsed: Set<EquationGroupID> = [], emptyMessage: String) {
            bridge.sendSticky("load", Self.payload(sheet, mode: mode, collapsed: collapsed, emptyMessage: emptyMessage))
        }

        func focus(entry id: EquationEntryID) {
            bridge.send("focusEntry", ["id": .string(id.raw)])
        }

        /// Pops a native menu at a point the page reported (CSS pixels → view points at the current zoom).
        func popUp(_ items: [PopupMenu.Item], at pagePoint: CGPoint) {
            guard let webView = bridge.webView else { return }
            let zoom = webView.pageZoom
            var point = NSPoint(x: pagePoint.x * zoom, y: pagePoint.y * zoom)
            if !webView.isFlipped { point.y = webView.bounds.height - point.y }
            PopupMenu.show(items, at: point, in: webView)
        }

        static func payload(_ sheet: EquationSheet, mode: Mode, collapsed: Set<EquationGroupID>, emptyMessage: String) -> JSONValue {
            .object([
                "mode": .string(mode.rawValue),
                "emptyMessage": .string(emptyMessage),
                "collapsed": .array(collapsed.map { .string($0.raw) }),
                "groups": .array(sheet.sections.map { section in
                    .object([
                        "id": .string(section.group.id.raw),
                        "name": .string(section.group.name),
                        "entries": .array(section.entries.map { entry in
                            var object: [String: JSONValue] = [
                                "id": .string(entry.id.raw),
                                "name": .string(entry.name),
                                "equations": .array(entry.equations.map { .string($0) }),
                            ]
                            if let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                                object["note"] = .string(note)
                            }
                            return .object(object)
                        }),
                    ])
                }),
            ])
        }
    }
}

/// The live equation fields of the entry editor (`web/equations/editor.html`): one MathLive field per equation,
/// configured like the answer form's, with the LaTeX shown under each.
struct EquationEditorWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "equations/editor.html", bridge: controller.bridge, theme: theme)
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        /// Content height reported by the page (fields, plus the virtual keyboard while it is up).
        private(set) var contentHeight: CGFloat = 0
        private(set) var isKeyboardVisible = false
        /// The equations as typed (on every edit), blanks included.
        var onChange: (([String]) -> Void)?
        /// Enter in the last field or ⌘⏎.
        var onSubmit: (() -> Void)?

        init() {
            bridge = WebBridge(name: "equation-editor")
            bridge.on("changed") { [weak self] payload in
                let list = payload["equations"]?.arrayValue?.compactMap(\.stringValue) ?? []
                self?.onChange?(list)
            }
            bridge.on("submit") { [weak self] _ in self?.onSubmit?() }
            bridge.on("height") { [weak self] payload in
                guard let px = payload["px"]?.doubleValue else { return }
                self?.contentHeight = CGFloat(px)
            }
            bridge.on("keyboardVisible") { [weak self] payload in
                self?.isKeyboardVisible = payload["visible"]?.boolValue ?? false
            }
        }

        func load(equations: [String]) {
            bridge.sendSticky("load", ["equations": .array(equations.map { .string($0) })])
        }

        func focus(index: Int) {
            bridge.send("focus", ["index": .number(Double(index))])
        }

        func setKeyboardVisible(_ visible: Bool) {
            isKeyboardVisible = visible
            bridge.send("setKeyboardVisible", ["visible": .bool(visible)])
        }
    }
}
