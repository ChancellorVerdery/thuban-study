import AppKit
import Foundation
import Observation
import ThubanCore

/// What the entry editor edits: a new entry (not yet stored) or a copy of a stored one.
struct EquationEntryDraft: Identifiable, Equatable {
    var id: EquationEntryID
    var isNew: Bool
    var groupId: EquationGroupID
    var name: String
    var note: String
    /// As typed, blanks included (they are dropped on save).
    var equations: [String]

    init(new groupId: EquationGroupID) {
        id = .new()
        isNew = true
        self.groupId = groupId
        name = ""
        note = ""
        equations = [""]
    }

    init(editing entry: EquationEntry) {
        id = entry.id
        isNew = false
        groupId = entry.groupId
        name = entry.name
        note = entry.note ?? ""
        equations = entry.equations.isEmpty ? [""] : entry.equations
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanedEquations: [String] { EquationEntry.cleaned(equations) }
    var canSave: Bool { !trimmedName.isEmpty && !cleanedEquations.isEmpty }
}

/// The Equations section and the Study panel of one class: the sheet as stored, the two searches, the panel's
/// collapsed groups, the page controllers, and what the section's sheets and confirmations are showing.
@MainActor
@Observable
final class EquationsState {
    private(set) var sheet: EquationSheet
    var isLoaded = false
    /// The Equations section's search.
    var search = ""
    /// The Study panel's own search.
    var panelSearch = ""
    /// Groups folded away in the Study panel.
    var collapsed: Set<EquationGroupID> = []

    let sheetPage = EquationSheetWebView.Controller(mode: .sheet)
    let panelPage = EquationSheetWebView.Controller(mode: .panel)
    /// The export workbench's page.
    let exportPage = EquationExportWebView.Controller()

    // Section UI
    var editing: EquationEntryDraft?
    /// Adding a new group (nil) or renaming one.
    var groupNaming: GroupNaming?
    var pendingDeleteEntry: EquationEntry?
    var pendingDeleteGroup: EquationSheet.Section?
    /// The export workbench is open.
    var isExporting = false
    var error: String?
    /// The last queued sheet change; the next one waits for it (see `ClassSession.enqueueSheetChange`).
    @ObservationIgnored var changeQueue: Task<Void, Never>?

    struct GroupNaming: Identifiable, Equatable {
        var group: EquationGroup?
        /// A new group made from the editor (for an entry) or from "Add a group".
        var id: String { group?.id.raw ?? "new" }
    }

    /// The Study panel's width, dragged by its leading edge; kept across launches.
    var panelWidth: CGFloat = EquationsState.savedPanelWidth {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: Self.panelWidthKey) }
    }
    static let panelWidthKey = "studyEquationsWidth"
    static let defaultPanelWidth: CGFloat = 340
    static let minPanelWidth: CGFloat = 260
    static var savedPanelWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: panelWidthKey)
        return saved >= Double(minPanelWidth) ? CGFloat(saved) : defaultPanelWidth
    }

    init(classId: ClassID) {
        sheet = EquationSheet(classId: classId)
    }

    func setSheet(_ sheet: EquationSheet) {
        self.sheet = sheet
        isLoaded = true
    }

    var filteredSheet: EquationSheet { sheet.filtered(by: search) }
    var filteredPanelSheet: EquationSheet { sheet.filtered(by: panelSearch) }

    /// Sends the (filtered) sheet to both pages.
    func push() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        sheetPage.load(filteredSheet, emptyMessage: query.isEmpty ? "" : "No equations match “\(query)”.")
        let panelQuery = panelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let panelEmpty = sheet.isEmpty
            ? "This class has no equations yet."
            : (panelQuery.isEmpty ? "" : "No equations match “\(panelQuery)”.")
        // While searching every matching group is open, so a match is never hidden in a folded group.
        panelPage.load(filteredPanelSheet, collapsed: panelQuery.isEmpty ? collapsed : [], emptyMessage: panelEmpty)
    }
}

extension ClassSession {
    private static var equationsStates: [ClassID: EquationsState] = [:]

    /// The equation-sheet state of this class (created on first access, wired to its pages).
    var equations: EquationsState {
        if let existing = Self.equationsStates[classId] { return existing }
        let state = EquationsState(classId: classId)
        Self.equationsStates[classId] = state
        let live = Set(app.classes.map(\.id))
        Self.equationsStates = Self.equationsStates.filter { live.contains($0.key) || $0.key == classId }
        wireEquationPages(state)
        return state
    }

    private func wireEquationPages(_ state: EquationsState) {
        for page in [state.sheetPage, state.panelPage] {
            let readOnly = page.mode == .panel
            page.onCopyLatex = { [weak self] entryId, index in self?.copyLatex(entryId, index: index) }
            page.onMenu = { [weak self, weak page] request in
                guard let self, let page else { return }
                page.popUp(self.menuItems(for: request, readOnly: readOnly), at: request.point)
            }
            guard !readOnly else { continue }
            page.onEdit = { [weak self] id in self?.editEquationEntry(id) }
            page.onAddEntry = { [weak self] groupId in self?.equations.editing = EquationEntryDraft(new: groupId) }
            page.onDeleteEntry = { [weak self] id in self?.confirmDeleteEquationEntry(id) }
            page.onMoveEntry = { [weak self] id, groupId, placement in
                self?.enqueueSheetChange { await self?.moveEquationEntry(id, to: groupId, placement: placement) }
            }
            page.onMoveEntryBy = { [weak self] id, delta in
                self?.enqueueSheetChange { await self?.moveEquationEntry(id, by: delta) }
            }
        }
        state.panelPage.onToggleGroup = { [weak state] groupId, collapsed in
            guard let state else { return }
            if collapsed { state.collapsed.insert(groupId) } else { state.collapsed.remove(groupId) }
        }
    }

    // MARK: Loading

    /// The export workbench's settings and selection for this class (`{settings, sel}`), nil before the first export.
    func equationExportChoices() async -> JSONValue? {
        try? await store.get(SettingsKey("equationExport.\(classId.raw)"), as: JSONValue.self)
    }

    func saveEquationExportChoices(_ value: JSONValue) async {
        do {
            try await store.set(SettingsKey("equationExport.\(classId.raw)"), value)
        } catch {
            Self.logger.error("save export choices failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadEquationSheet() async {
        do {
            let sheet = try await store.equationSheet(for: classId)
            equations.setSheet(sheet)
            equations.collapsed.formIntersection(Set(sheet.groups.map(\.id)))
            equations.push()
        } catch {
            equations.error = error.localizedDescription
            Self.logger.error("load equation sheet failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs sheet changes one after another, so each starts from the sheet the one before left (two quick ⌥↓
    /// presses move a card two places, not one).
    func enqueueSheetChange(_ operation: @escaping @MainActor () async -> Void) {
        let previous = equations.changeQueue
        equations.changeQueue = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Runs a store change, then reloads and redraws the sheet; failures surface in the section's error line.
    private func changeSheet(_ change: () async throws -> Void) async {
        do {
            try await change()
            equations.error = nil
        } catch {
            equations.error = error.localizedDescription
        }
        await loadEquationSheet()
    }

    // MARK: Groups

    @discardableResult
    func addEquationGroup(named name: String) async -> EquationGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var added: EquationGroup?
        await changeSheet { added = try await store.addEquationGroup(named: trimmed, to: classId) }
        return added
    }

    func renameEquationGroup(_ id: EquationGroupID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await changeSheet { try await store.renameEquationGroup(id, to: trimmed) }
    }

    func deleteEquationGroup(_ id: EquationGroupID) async {
        await changeSheet { try await store.deleteEquationGroup(id) }
    }

    func moveEquationGroup(_ id: EquationGroupID, by delta: Int) async {
        await changeSheet { try await store.moveEquationGroup(id, by: delta) }
    }

    func confirmDeleteEquationGroup(_ id: EquationGroupID) {
        equations.pendingDeleteGroup = equations.sheet.sections.first { $0.group.id == id }
    }

    // MARK: Entries

    func editEquationEntry(_ id: EquationEntryID) {
        guard let entry = equations.sheet.entry(id) else { return }
        equations.editing = EquationEntryDraft(editing: entry)
    }

    /// Saves the editor's draft: inserts a new entry at the end of its group, or updates the stored one (a changed
    /// group moves it to the end of that group).
    func saveEquationEntry(_ draft: EquationEntryDraft) async -> Bool {
        guard draft.canSave else { return false }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        var failed = false
        await changeSheet {
            do {
                if draft.isNew {
                    let entry = EquationEntry(id: draft.id, groupId: draft.groupId, name: draft.trimmedName,
                                              equations: draft.cleanedEquations, note: note.isEmpty ? nil : note)
                    try await store.addEquationEntry(entry, at: nil)
                } else if var entry = equations.sheet.entry(draft.id) {
                    entry.groupId = draft.groupId
                    entry.name = draft.trimmedName
                    entry.equations = draft.cleanedEquations
                    entry.note = note.isEmpty ? nil : note
                    try await store.updateEquationEntry(entry)
                }
            } catch {
                failed = true
                throw error
            }
        }
        if !failed { equations.sheetPage.focus(entry: draft.id) }
        return !failed
    }

    func confirmDeleteEquationEntry(_ id: EquationEntryID) {
        equations.pendingDeleteEntry = equations.sheet.entry(id)
    }

    func deleteEquationEntry(_ id: EquationEntryID) async {
        await changeSheet { try await store.deleteEquationEntry(id) }
    }

    func moveEquationEntry(_ id: EquationEntryID, to groupId: EquationGroupID, placement: EquationEntryPlacement) async {
        await changeSheet { try await store.moveEquationEntry(id, to: groupId, placement: placement) }
        equations.sheetPage.focus(entry: id)
    }

    /// Move up / Move down within the entry's group, past the neighbour the user can see: with no search that is
    /// the next stored entry (resolved in the store's transaction); while searching it is the next matching entry,
    /// so the card visibly moves instead of stepping past a hidden one.
    func moveEquationEntry(_ id: EquationEntryID, by delta: Int) async {
        guard delta != 0 else { return }
        if equations.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await changeSheet { try await store.moveEquationEntry(id, by: delta) }
        } else {
            guard let section = equations.filteredSheet.sections.first(where: { $0.entries.contains { $0.id == id } }),
                  let index = section.entries.firstIndex(where: { $0.id == id }),
                  section.entries.indices.contains(index + delta) else { return }
            let neighbour = section.entries[index + delta].id
            await changeSheet {
                try await store.moveEquationEntry(id, to: section.group.id,
                                                  placement: delta < 0 ? .before(neighbour) : .after(neighbour))
            }
        }
        equations.sheetPage.focus(entry: id)
    }

    // MARK: Copy

    /// Copies one equation's LaTeX (`index`), or every equation of the entry one per line.
    func copyLatex(_ id: EquationEntryID, index: Int?) {
        guard let entry = equations.sheet.entry(id) else { return }
        let text: String
        if let index, entry.equations.indices.contains(index) {
            text = entry.equations[index]
        } else {
            text = entry.equations.joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Menus

    /// The native context menu for a right-click (or "…" / menu key) on the sheet page. The Study panel is
    /// read-only: it offers copying and a jump to the editable sheet.
    func menuItems(for request: EquationSheetWebView.MenuRequest, readOnly: Bool) -> [PopupMenu.Item] {
        let sheet = equations.sheet
        var items: [PopupMenu.Item] = []

        if let entryId = request.entryId, let entry = sheet.entry(entryId) {
            if let index = request.index, request.kind == .equation, entry.equations.indices.contains(index) {
                items.append(.action(entry.isList ? "Copy LaTeX of Equation \(index + 1)" : "Copy LaTeX") {
                    self.copyLatex(entryId, index: index)
                })
                if entry.isList {
                    items.append(.action("Copy LaTeX of All \(entry.equations.count)") { self.copyLatex(entryId, index: nil) })
                }
            } else if entry.isList {
                items.append(.submenu("Copy LaTeX", entry.equations.indices.map { index in
                    .action("Equation \(index + 1)") { self.copyLatex(entryId, index: index) }
                } + [.separator, .action("All \(entry.equations.count), One per Line") { self.copyLatex(entryId, index: nil) }]))
            } else {
                items.append(.action("Copy LaTeX") { self.copyLatex(entryId, index: nil) })
            }

            if readOnly {
                items.append(.separator)
                items.append(.action("Edit in Equation Sheet") {
                    self.section = .equations
                    self.editEquationEntry(entryId)
                })
                return items
            }

            // Positions as the user sees them (the search may hide some entries).
            guard let section = equations.filteredSheet.sections.first(where: { $0.group.id == entry.groupId }),
                  let position = section.entries.firstIndex(where: { $0.id == entryId }) else { return items }
            items.insert(.action("Edit…") { self.editEquationEntry(entryId) }, at: 0)
            items.insert(.separator, at: 1)
            items.append(.separator)
            items.append(.action("Move Up", enabled: position > 0) {
                self.enqueueSheetChange { await self.moveEquationEntry(entryId, by: -1) }
            })
            items.append(.action("Move Down", enabled: position < section.entries.count - 1) {
                self.enqueueSheetChange { await self.moveEquationEntry(entryId, by: 1) }
            })
            let others = sheet.groups.filter { $0.id != entry.groupId }
            items.append(.submenu("Move to Group", others.map { group in
                .action(group.name) {
                    self.enqueueSheetChange { await self.moveEquationEntry(entryId, to: group.id, placement: .end) }
                }
            }))
            items.append(.separator)
            items.append(.action("Delete…") { self.confirmDeleteEquationEntry(entryId) })
            return items
        }

        guard !readOnly, request.kind == .group,
              let index = sheet.groups.firstIndex(where: { $0.id == request.groupId }) else { return items }
        let group = sheet.groups[index]
        return [
            .action("Add Equation…") { self.equations.editing = EquationEntryDraft(new: group.id) },
            .action("Rename Group…") { self.equations.groupNaming = EquationsState.GroupNaming(group: group) },
            .separator,
            .action("Move Group Up", enabled: index > 0) {
                self.enqueueSheetChange { await self.moveEquationGroup(group.id, by: -1) }
            },
            .action("Move Group Down", enabled: index < sheet.groups.count - 1) {
                self.enqueueSheetChange { await self.moveEquationGroup(group.id, by: 1) }
            },
            .separator,
            .action("Delete Group…") { self.confirmDeleteEquationGroup(group.id) },
        ]
    }
}
