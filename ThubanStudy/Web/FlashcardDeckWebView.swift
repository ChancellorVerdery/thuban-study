import AppKit
import SwiftUI
import ThubanCore

/// The flashcards page (`web/flashcards/deck.html`): one face of the card under review, the card bank list, or the
/// editor's preview — Markdown with rendered LaTeX throughout. Swift owns the deck and the session; the page draws
/// and reports clicks and review keys.
struct FlashcardDeckWebView: View {
    @Environment(\.thubanTheme) private var theme
    var controller: Controller

    var body: some View {
        BridgeWebView(page: "flashcards/deck.html", bridge: controller.bridge, theme: theme)
    }

    struct BankRow {
        enum Chip: String { case new, due, later }
        var id: FlashcardID
        var front: String
        var back: String
        var chip: String
        var chipKind: Chip
    }

    @MainActor
    @Observable
    final class Controller {
        let bridge: WebBridge
        var onFlip: (() -> Void)?
        /// " ", "1", "2" or "Escape" pressed while the page has focus.
        var onKey: ((String) -> Void)?
        var onEdit: ((FlashcardID) -> Void)?
        var onDelete: ((FlashcardID) -> Void)?
        /// A generated card ticked (true) or unticked.
        var onToggle: ((Int, Bool) -> Void)?

        init(name: String) {
            bridge = WebBridge(name: name)
            bridge.on("flip") { [weak self] _ in self?.onFlip?() }
            bridge.on("key") { [weak self] payload in
                guard let key = payload["key"]?.stringValue else { return }
                self?.onKey?(key)
            }
            bridge.on("edit") { [weak self] payload in
                guard let id = payload["id"]?.stringValue else { return }
                self?.onEdit?(FlashcardID(raw: id))
            }
            bridge.on("toggle") { [weak self] payload in
                guard let index = payload["index"]?.doubleValue else { return }
                self?.onToggle?(Int(index), payload["on"]?.boolValue ?? true)
            }
            bridge.on("delete") { [weak self] payload in
                guard let id = payload["id"]?.stringValue else { return }
                self?.onDelete?(FlashcardID(raw: id))
            }
        }

        func showCard(side: String, text: String, hint: String) {
            bridge.sendSticky("card", ["side": .string(side), "text": .string(text), "hint": .string(hint)])
        }

        func showBank(_ rows: [BankRow], emptyMessage: String) {
            bridge.sendSticky("bank", [
                "emptyMessage": .string(emptyMessage),
                "cards": .array(rows.map { row in
                    .object([
                        "id": .string(row.id.raw), "front": .string(row.front), "back": .string(row.back),
                        "chip": .string(row.chip), "chipKind": .string(row.chipKind.rawValue),
                    ])
                }),
            ])
        }

        func showPick(_ cards: [(front: String, back: String, on: Bool)]) {
            bridge.sendSticky("pick", ["cards": .array(cards.map {
                .object(["front": .string($0.front), "back": .string($0.back), "on": .bool($0.on)])
            })])
        }

        func showPreview(front: String, back: String) {
            bridge.sendSticky("preview", ["front": .string(front), "back": .string(back)])
        }

        /// Gives the page keyboard focus (review keys go to it).
        func focus() {
            guard let webView = bridge.webView else { return }
            webView.window?.makeFirstResponder(webView)
        }
    }
}
