import SwiftUI
import ThubanCore

/// The Equations section: this class's hand-curated equation sheet. Header (title, counts, search, Add group /
/// Add equation), then the sheet page — groups under micro eyebrows, entries as cards in as many columns as fit.
/// Cards open the entry editor (double-click, Enter, or the context menu); every action is also in the native
/// context menu and on the keyboard.
struct EquationSheetView: View {
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession
    @FocusState private var searchFocused: Bool

    private var state: EquationsState { session.equations }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0.z) {
            header
                .padding(.horizontal, 24.z)
                .padding(.top, 22.z)
                .padding(.bottom, 12.z)
            if let error = state.error {
                Text(error)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.negTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24.z)
                    .padding(.bottom, 8.z)
            }
            Rectangle().fill(theme.lineColor).frame(height: 1)
            if state.isLoaded, state.sheet.isEmpty {
                EmptyState(icon: .equations, title: "No equations yet",
                           message: "Build this class's equation sheet by hand: make a group such as “Derivatives”, then add the equations you want within reach while you study.") {
                    Button("Add a group") { state.groupNaming = EquationsState.GroupNaming(group: nil) }
                        .buttonStyle(.thubanPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                EquationSheetWebView(controller: state.sheetPage)
                    .accessibilityLabel("Equation sheet")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: session.classId) { await session.loadEquationSheet() }
        .onChange(of: state.search) { _, _ in state.push() }
        .sheet(item: $state.editing) { draft in
            EquationEntryEditor(session: session, draft: draft)
                .environment(\.thubanTheme, theme)
        }
        .sheet(isPresented: $state.isExporting) {
            EquationExportSheet(session: session)
                .environment(\.thubanTheme, theme)
        }
        .sheet(item: $state.groupNaming) { naming in
            EquationGroupNameSheet(session: session, group: naming.group)
                .environment(\.thubanTheme, theme)
        }
        .confirmationDialog(
            "Delete “\(state.pendingDeleteEntry?.name ?? "")”?",
            isPresented: Binding(get: { state.pendingDeleteEntry != nil }, set: { if !$0 { state.pendingDeleteEntry = nil } }),
            presenting: state.pendingDeleteEntry
        ) { entry in
            Button("Delete", role: .destructive) { Task { await session.deleteEquationEntry(entry.id) } }
            Button("Keep", role: .cancel) {}
        } message: { entry in
            Text(entry.isList
                 ? "Its \(entry.equations.count) equations will be removed from the sheet. This cannot be undone."
                 : "The equation will be removed from the sheet. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete the group “\(state.pendingDeleteGroup?.group.name ?? "")”?",
            isPresented: Binding(get: { state.pendingDeleteGroup != nil }, set: { if !$0 { state.pendingDeleteGroup = nil } }),
            presenting: state.pendingDeleteGroup
        ) { section in
            Button(section.entries.isEmpty ? "Delete group" : "Delete group and \(pluralized(section.entries.count, "entry", "entries"))",
                   role: .destructive) {
                Task { await session.deleteEquationGroup(section.group.id) }
            }
            Button("Keep", role: .cancel) {}
        } message: { section in
            Text(section.entries.isEmpty
                 ? "The empty group will be removed."
                 : "Everything in it goes too. Move entries to another group first to keep them. This cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var state = state
        return HStack(alignment: .center, spacing: 16.z) {
            VStack(alignment: .leading, spacing: 4.z) {
                Text("Equation sheet")
                    .font(ThubanFont.display(28))
                    .foregroundStyle(theme.inkColor)
                Text(subtitle)
                    .font(ThubanFont.body(15))
                    .foregroundStyle(theme.inkDimColor)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            if !state.sheet.isEmpty {
                SearchField(placeholder: "Search equations  ⌘F", label: "Search equations",
                            text: $state.search, focused: $searchFocused)
                    .frame(width: 260.z)
            }
            // An empty sheet has one action, the empty state's primary "Add a group".
            if state.sheet.entryCount > 0 {
                Button("Export…") { state.isExporting = true }
                    .buttonStyle(.thubanSecondary)
                    .keyboardShortcut("p", modifiers: .command)
                    .help("Lay the sheet out on paper or index cards and export a PDF or print (⌘P)")
            }
            if !state.sheet.isEmpty {
                Button("Add group") { state.groupNaming = EquationsState.GroupNaming(group: nil) }
                    .buttonStyle(.thubanSecondary)
                    .help("Add a group, such as “Series tests”")
            }
            if let first = state.sheet.groups.first {
                Button {
                    state.editing = EquationEntryDraft(new: first.id)
                } label: {
                    HStack(spacing: 6.z) {
                        Glyph(.plus, size: 14)
                        Text("Add equation")
                    }
                }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Add an equation (⌘⇧N)")
            }
        }
    }

    private var subtitle: String {
        let sheet = state.sheet
        guard state.isLoaded else { return " " }
        if sheet.isEmpty { return "\(session.studyClass?.name ?? "This class") · nothing on the sheet yet" }
        var line = pluralized(sheet.entryCount, "entry", "entries") + " in " + pluralized(sheet.sections.count, "group", "groups")
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            line += " · \(state.filteredSheet.entryCount) matching"
        }
        return line
    }
}

/// "1 entry" / "3 entries".
func pluralized(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}

// MARK: - Group name

/// Add a group, or rename one.
struct EquationGroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    var session: ClassSession
    var group: EquationGroup?
    /// Called with a newly added group (the entry editor selects it).
    var onAdded: ((EquationGroup) -> Void)?
    @State private var name = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    var body: some View {
        ModalCard(title: group == nil ? "New group" : "Rename group") {
            LabeledField("Group name") {
                TextField("Series tests", text: $name)
                    .thubanField()
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityLabel("Group name")
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button(group == nil ? "Add group" : "Rename", action: save)
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        }
        .onAppear {
            name = group?.name ?? ""
            focused = true
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            if let group {
                await session.renameEquationGroup(group.id, to: name)
            } else if let added = await session.addEquationGroup(named: name) {
                onAdded?(added)
            }
            dismiss()
        }
    }
}
