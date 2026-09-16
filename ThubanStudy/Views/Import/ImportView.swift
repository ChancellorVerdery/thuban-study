import AppKit
import SwiftUI
import ThubanCore
import UniformTypeIdentifiers

/// PLACEHOLDER — the screens phase replaces this file wholesale. Drop zone + the class's document rows.
struct ImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone
            if session.importQueue.isEmpty {
                Text("No documents yet.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.importQueue) { document in
                            HStack(spacing: 12) {
                                Icon(.importDocs, size: 16).foregroundStyle(theme.inkDimColor)
                                Text(document.filename)
                                    .font(ThubanFont.body(14))
                                    .foregroundStyle(theme.inkColor)
                                    .lineLimit(1)
                                Text(document.kind.rawValue.uppercased())
                                    .font(ThubanFont.mono(11))
                                    .foregroundStyle(theme.inkFaintColor)
                                Spacer()
                                Chip.importStatus(document)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            Rectangle().fill(theme.lineColor).frame(height: 1)
                        }
                    }
                    .thubanPanel(padding: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .task(id: session.classId) { await session.loadDocuments() }
        .onChange(of: app.importPanelRequest) { _, _ in openPanel() }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Icon(.importDocs, size: 28).foregroundStyle(theme.brassInkColor)
            Text("Drop documents here")
                .font(ThubanFont.display(20))
                .foregroundStyle(theme.inkColor)
            Text("PDF, Word, Excel, CSV, HTML, MHTML, PowerPoint, images")
                .font(ThubanFont.small)
                .foregroundStyle(theme.inkDimColor)
            Button("Choose files…") { openPanel() }
                .buttonStyle(.thubanSecondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(isTargeted ? theme.accentTintColor : theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ThubanMetrics.cardRadius, style: .continuous)
                .strokeBorder(isTargeted ? theme.accentColor : theme.line2Color, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await session.enqueue(urls: files) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentParserRegistry.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose documents to import into \(session.studyClass?.name ?? "this class")"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await session.enqueue(urls: urls) }
        }
    }
}
