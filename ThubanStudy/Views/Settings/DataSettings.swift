import AppKit
import SwiftUI
import ThubanCore
import UniformTypeIdentifiers

// MARK: - Model

/// Storage facts for the Data & storage pane, plus export and delete-all actions.
@MainActor
@Observable
final class DataSettingsModel {
    private(set) var sizeBytes: Int64?
    private(set) var sizeError: String?
    private(set) var isExporting = false
    private(set) var exportNote: (text: String, tone: SettingsNote.Tone)?
    private(set) var isDeleting = false
    private(set) var deleteError: String?

    @ObservationIgnored private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// The directory shown to the user: the database's folder, or the app-support root for an in-memory store.
    var dataDirectory: URL {
        app.store.locations.database?.deletingLastPathComponent() ?? AppPaths.baseDirectory
    }

    var isInMemory: Bool { app.store.locations.database == nil }

    var displayPath: String {
        let path = dataDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var formattedSize: String {
        guard let sizeBytes else { return "…" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    func refreshSize() async {
        do {
            sizeBytes = try await app.store.storageSize()
            sizeError = nil
        } catch {
            sizeError = error.localizedDescription
        }
    }

    func revealInFinder() {
        let url = dataDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    /// Asks for a destination and writes the archive (database snapshot + documents + figures).
    func export() async {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Thuban Study data"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.suggestedExportName()
        panel.directoryURL = AppPaths.exports
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        exportNote = nil
        defer { isExporting = false }
        do {
            try await app.store.exportArchive(to: url)
            exportNote = ("Exported to \(url.lastPathComponent).", .positive)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportNote = (error.localizedDescription, .negative)
        }
        await refreshSize()
    }

    /// Removes every class, all settings and the stored files. Returns true on success.
    @discardableResult
    func deleteAllData() async -> Bool {
        guard !isDeleting else { return false }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await app.deleteAllData()
            await refreshSize()
            return true
        } catch {
            deleteError = error.localizedDescription
            return false
        }
    }

    static func suggestedExportName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Thuban Study \(formatter.string(from: date)).zip"
    }
}

// MARK: - Pane

/// Data & storage: where the data lives, how big it is, export / reveal, and the delete-all danger zone.
struct DataSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme

    @State private var model: DataSettingsModel?
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let model {
                locationGroup(model)
                dangerGroup(model)
            }
        }
        .onAppear {
            if model == nil { model = DataSettingsModel(app: app) }
        }
        .task(id: model == nil) {
            await model?.refreshSize()
        }
        .sheet(isPresented: $isConfirmingDelete) {
            if let model {
                DeleteAllDataSheet(model: model)
                    .environment(\.thubanTheme, app.theme)
            }
        }
    }

    private func locationGroup(_ model: DataSettingsModel) -> some View {
        SettingsGroup("Location", caption: "All data is stored on this Mac. Nothing is synced or uploaded except the requests the tutor and import agent make to Claude.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Icon(.importDocs, size: 20)
                        .foregroundStyle(theme.brassInkColor)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All data is stored on this Mac")
                            .font(ThubanFont.display(18))
                            .foregroundStyle(theme.inkColor)
                        Text(model.displayPath)
                            .font(ThubanFont.mono(13))
                            .foregroundStyle(theme.inkDimColor)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack(spacing: 14) {
                            fact("Size", model.formattedSize)
                            fact("Classes", "\(app.classes.count)")
                            fact("Database", model.isInMemory ? "in memory (not saved)" : "thuban.sqlite")
                        }
                        if let sizeError = model.sizeError {
                            SettingsNote(sizeError, tone: .negative)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                HStack(spacing: 10) {
                    Button(model.isExporting ? "Exporting…" : "Export…") { Task { await model.export() } }
                        .buttonStyle(.thubanPrimary)
                        .disabled(model.isExporting)
                        .help("Save a zip of the database, documents and figures")
                    Button("Reveal in Finder") { model.revealInFinder() }
                        .buttonStyle(.thubanSecondary)
                    Button("Refresh size") { Task { await model.refreshSize() } }
                        .buttonStyle(.thubanGhost)
                    Spacer()
                }
                if let note = model.exportNote {
                    SettingsNote(note.text, tone: note.tone)
                }
                Text("An export is a zip with a consistent snapshot of the database and every imported file. Keychain credentials are never included.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .thubanPanel(padding: 20)
        }
    }

    private func dangerGroup(_ model: DataSettingsModel) -> some View {
        SettingsGroup("Danger zone") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delete all data")
                        .font(ThubanFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.inkColor)
                    Text("Removes every class, question bank, attempt, transcript, imported file and setting. Your Claude connection stays. This cannot be undone.")
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let deleteError = model.deleteError {
                        SettingsNote(deleteError, tone: .negative)
                    }
                }
                Spacer(minLength: 12)
                Button("Delete all data…") { isConfirmingDelete = true }
                    .buttonStyle(.thubanDangerOutline)
                    .disabled(model.isDeleting)
            }
            .padding(20)
            .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                    .strokeBorder(theme.negColor, lineWidth: ThubanMetrics.hairline)
            )
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(ThubanFont.micro)
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(theme.inkDimColor)
            Text(value)
                .font(ThubanFont.body(14, weight: .semibold))
                .foregroundStyle(theme.inkColor)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Typed confirmation

/// "Type DELETE to confirm" before wiping everything.
private struct DeleteAllDataSheet: View {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var model: DataSettingsModel
    @State private var typed = ""

    private static let phrase = "DELETE"
    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces) == Self.phrase }

    var body: some View {
        ModalCard(title: "Delete all data?") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    DangerGlyph(size: 22)
                        .foregroundStyle(theme.negTextColor)
                    Text("Every class, question, attempt, transcript, imported file and setting on this Mac will be removed. Export first if you might want any of it back.")
                        .font(ThubanFont.body(14))
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledField("Type \(Self.phrase) to confirm") {
                    TextField(Self.phrase, text: $typed)
                        .thubanField(mono: true)
                        .onSubmit { if matches { confirm() } }
                        .accessibilityLabel("Type \(Self.phrase) to confirm")
                }
                if let error = model.deleteError {
                    SettingsNote(error, tone: .negative)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.thubanSecondary)
                .keyboardShortcut(.cancelAction)
            Button(model.isDeleting ? "Deleting…" : "Delete all data") { confirm() }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(!matches || model.isDeleting)
        }
    }

    private func confirm() {
        Task {
            if await model.deleteAllData() { dismiss() }
        }
    }
}

/// A warning triangle in the icon set's stroke style (not part of the 12 icons; drawn inline).
struct DangerGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var triangle = Path()
            triangle.move(to: p(12, 3.5))
            triangle.addLine(to: p(21, 19.5))
            triangle.addLine(to: p(3, 19.5))
            triangle.closeSubpath()
            var mark = Path()
            mark.move(to: p(12, 9)); mark.addLine(to: p(12, 13.5))
            mark.move(to: p(12, 16.5)); mark.addLine(to: p(12.01, 16.5))
            let style = StrokeStyle(lineWidth: 1.75 * s, lineCap: .round, lineJoin: .round)
            context.stroke(triangle, with: .foreground, style: style)
            context.stroke(mark, with: .foreground, style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
