import SwiftUI
import ThubanCore

/// Add or edit one entry of the equation sheet: its name, its group, one or more equations typed in live MathLive
/// fields (the answer form's shortcuts and keyboard, with the LaTeX shown under each), and an optional note.
struct EquationEntryEditor: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var session: ClassSession

    @State private var draft: EquationEntryDraft
    @State private var page = EquationEditorWebView.Controller()
    @State private var keyboardOn = false
    @State private var newGroupName = ""
    @State private var isAddingGroup = false
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, note, newGroup }

    init(session: ClassSession, draft: EquationEntryDraft) {
        self.session = session
        _draft = State(initialValue: draft)
    }

    private var groups: [EquationGroup] { session.equations.sheet.groups }

    var body: some View {
        ModalCard(title: draft.isNew ? "New equation" : "Edit equation", width: 640) {
            VStack(alignment: .leading, spacing: 16.z) {
                HStack(alignment: .top, spacing: 12.z) {
                    LabeledField("Name") {
                        TextField("Chain rule", text: $draft.name)
                            .thubanField()
                            .focused($focus, equals: .name)
                            .onSubmit(save)
                            .accessibilityLabel("Name")
                    }
                    LabeledField("Group") { groupControl }
                        .frame(width: 230.z)
                }

                VStack(alignment: .leading, spacing: 6.z) {
                    HStack(alignment: .center) {
                        Text(draft.equations.count > 1 ? "Equations · a named list" : "Equation")
                            .font(ThubanFont.micro)
                            .textCase(.uppercase)
                            .kerning(0.5)
                            .foregroundStyle(theme.inkDimColor)
                        Spacer()
                        ToggleChip(label: "Keyboard", icon: .mathKeyboard, isOn: $keyboardOn)
                    }
                    EquationEditorWebView(controller: page)
                        .frame(height: min(max(page.contentHeight * AppZoom.shared.scale, 110.z), 520.z))
                        .accessibilityLabel("Equation fields")
                    Text("Type math as in an answer box. One equation makes a card; add more to make a named list. Enter moves to the next field, ⌘⏎ saves.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledField("Note · optional") {
                    TextField("Conditions, e.g. for |r| < 1", text: $draft.note)
                        .thubanField()
                        .focused($focus, equals: .note)
                        .onSubmit(save)
                        .accessibilityLabel("Note")
                }

                if let error {
                    Text(error)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.negTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button(isSaving ? "Saving…" : (draft.isNew ? "Add to sheet" : "Save")) { save() }
                .buttonStyle(.thubanPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.canSave || isSaving)
                .help(draft.canSave ? "Save (⌘⏎)" : "Give the entry a name and at least one equation")
        }
        .leadingAction(deleteButton)
        .onAppear {
            page.onChange = { list in draft.equations = list }
            page.onSubmit = { save() }
            page.load(equations: draft.equations)
            if draft.isNew { focus = .name }
        }
        .onChange(of: keyboardOn) { _, on in
            if page.isKeyboardVisible != on { page.setKeyboardVisible(on) }
        }
        .onChange(of: page.isKeyboardVisible) { _, visible in
            if keyboardOn != visible { keyboardOn = visible }
        }
    }

    /// Delete… for a stored entry (nothing for a new one), on the leading edge away from Save.
    @ViewBuilder
    private var deleteButton: some View {
        if !draft.isNew {
            Button("Delete…") {
                let id = draft.id
                dismiss()
                session.confirmDeleteEquationEntry(id)
            }
            .buttonStyle(.thubanDangerOutline)
        }
    }

    // MARK: Group

    @ViewBuilder
    private var groupControl: some View {
        if isAddingGroup {
            HStack(spacing: 6.z) {
                TextField("New group", text: $newGroupName)
                    .thubanField()
                    .focused($focus, equals: .newGroup)
                    .onSubmit(addGroup)
                    .onExitCommand { isAddingGroup = false }
                    .accessibilityLabel("New group name")
                IconButton(glyph: .check, label: "Add group", size: 30, iconSize: 14, tinted: true, action: addGroup)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            Menu {
                ForEach(groups) { group in
                    Button {
                        draft.groupId = group.id
                    } label: {
                        if group.id == draft.groupId {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                }
                Divider()
                Button("New group…") {
                    newGroupName = ""
                    isAddingGroup = true
                    focus = .newGroup
                }
            } label: {
                HStack(spacing: 6.z) {
                    Text(groups.first { $0.id == draft.groupId }?.name ?? "Choose a group")
                        .font(ThubanFont.body(14))
                        .foregroundStyle(theme.inkColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Glyph(.chevronDown, size: 13)
                        .foregroundStyle(theme.inkDimColor)
                }
                .padding(.horizontal, 10.z)
                .frame(height: ThubanMetrics.buttonHeight)
                .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                        .strokeBorder(theme.line2Color, lineWidth: ThubanMetrics.hairline)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Group")
            .accessibilityValue(groups.first { $0.id == draft.groupId }?.name ?? "none")
        }
    }

    private func addGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            if let group = await session.addEquationGroup(named: name) {
                draft.groupId = group.id
            }
            isAddingGroup = false
        }
    }

    // MARK: Save

    private func save() {
        guard draft.canSave, !isSaving else {
            if draft.trimmedName.isEmpty {
                error = "Give the entry a name."
                focus = .name
            } else if draft.cleanedEquations.isEmpty {
                error = "Type at least one equation."
                page.focus(index: 0)
            }
            return
        }
        isSaving = true
        error = nil
        if page.isKeyboardVisible { page.setKeyboardVisible(false) }
        Task {
            if await session.saveEquationEntry(draft) {
                dismiss()
            } else {
                error = session.equations.error ?? "The entry could not be saved."
                isSaving = false
            }
        }
    }
}
