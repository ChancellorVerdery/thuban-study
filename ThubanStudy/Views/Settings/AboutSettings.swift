import AppKit
import SwiftUI
import ThubanCore

/// About pane: the app mark, name and version, links, and the projects Thuban Study is built on.
struct AboutSettings: View {
    @Environment(\.thubanTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 28.z) {
            identityCard

            SettingsGroup("Links") {
                VStack(spacing: 0.z) {
                    ForEach(Array(AboutLink.all.enumerated()), id: \.element.id) { index, link in
                        AboutLinkRow(link: link)
                        if index < AboutLink.all.count - 1 {
                            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                        }
                    }
                }
                .thubanPanel(padding: 0)
            }

            SettingsGroup("Acknowledgements", caption: "Open-source projects and services Thuban Study is built on. Licenses are noted per project.") {
                VStack(spacing: 0.z) {
                    ForEach(Array(Acknowledgement.all.enumerated()), id: \.element.id) { index, item in
                        AcknowledgementRow(item: item)
                        if index < Acknowledgement.all.count - 1 {
                            Rectangle().fill(theme.lineColor).frame(height: ThubanMetrics.hairline)
                        }
                    }
                }
                .thubanPanel(padding: 0)
            }
        }
    }

    private var identityCard: some View {
        HStack(alignment: .center, spacing: 18.z) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.bgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(theme.lineColor, lineWidth: ThubanMetrics.hairline)
                    )
                AppArtView(size: 40, theme: theme)
            }
            .frame(width: 72.z, height: 72.z)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6.z) {
                Text(AppInfo.name)
                    .font(ThubanFont.display(24))
                    .foregroundStyle(theme.inkColor)
                HStack(spacing: 8.z) {
                    Text("Version \(AppInfo.version)")
                        .font(ThubanFont.body(14))
                        .foregroundStyle(theme.inkDimColor)
                    Text("(\(AppInfo.build))")
                        .font(ThubanFont.mono(12))
                        .foregroundStyle(theme.inkFaintColor)
                    Chip("macOS 15+", kind: .neutral)
                }
                .textSelection(.enabled)
                Text("Named after Thuban, Alpha Draconis — the old pole star. Import your course material, let the agent build a question bank, and work problems beside a tutor that guides, never solves.")
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .thubanPanel(padding: 20)
    }
}

// MARK: - App facts

/// Name and version read from the bundle.
enum AppInfo {
    static var name: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Thuban Study"
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.thuban.study"
    }
}

/// External links shown on the About pane.
struct AboutLink: Identifiable {
    var title: String
    var detail: String
    var url: URL
    var id: String { title }

    static let all: [AboutLink] = [
        URL(string: "https://claude.ai/artifact/MbqgQgK5BeX9tkoCsXkV9X").map {
            AboutLink(title: "Design canvas", detail: "Every screen of Thuban Study as it was designed.", url: $0)
        },
        URL(string: "https://www.desmos.com/api").map {
            AboutLink(title: "Desmos API", detail: "Where the grapher and calculator key comes from.", url: $0)
        },
        URL(string: "https://console.anthropic.com").map {
            AboutLink(title: "Anthropic Console", detail: "Manage API keys for the tutor and the import agent.", url: $0)
        },
    ].compactMap { $0 }
}

private struct AboutLinkRow: View {
    @Environment(\.thubanTheme) private var theme
    var link: AboutLink
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(link.url)
        } label: {
            HStack(spacing: 12.z) {
                VStack(alignment: .leading, spacing: 2.z) {
                    Text(link.title)
                        .font(ThubanFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.brassInkColor)
                    Text(link.detail)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                }
                Spacer(minLength: 12)
                Text(link.url.host() ?? link.url.absoluteString)
                    .font(ThubanFont.mono(12))
                    .foregroundStyle(theme.inkFaintColor)
                Glyph(.chevronRight, size: 14)
                    .foregroundStyle(theme.inkFaintColor)
            }
            .padding(.horizontal, 16.z)
            .padding(.vertical, 12.z)
            .background(hovering ? theme.panel2Color : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(link.title), opens \(link.url.absoluteString) in the browser")
    }
}

// MARK: - Acknowledgements

/// A third-party project Thuban Study depends on, with its license.
struct Acknowledgement: Identifiable {
    var name: String
    var role: String
    var license: String
    var url: URL?
    var id: String { name }

    static let all: [Acknowledgement] = [
        Acknowledgement(name: "MathLive", role: "Math input fields and the virtual keyboard", license: "MIT", url: URL(string: "https://cortexjs.io/mathlive/")),
        Acknowledgement(name: "Cortex Compute Engine", role: "Symbolic math for grading and template generation", license: "MIT", url: URL(string: "https://cortexjs.io/compute-engine/")),
        Acknowledgement(name: "Desmos", role: "2D/3D grapher and scientific calculator", license: "Desmos API terms", url: URL(string: "https://www.desmos.com/api")),
        Acknowledgement(name: "GRDB.swift", role: "SQLite database", license: "MIT", url: URL(string: "https://github.com/groue/GRDB.swift")),
        Acknowledgement(name: "ZIPFoundation", role: "Reading Office files and writing exports", license: "MIT", url: URL(string: "https://github.com/weichsel/ZIPFoundation")),
        Acknowledgement(name: "SwiftSoup", role: "HTML and Office XML parsing", license: "MIT", url: URL(string: "https://github.com/scinfu/SwiftSoup")),
        Acknowledgement(name: "CoreXLSX", role: "Excel workbooks", license: "Apache 2.0", url: URL(string: "https://github.com/CoreOffice/CoreXLSX")),
        Acknowledgement(name: "marked", role: "Markdown rendering in the question form and tutor chat", license: "MIT", url: URL(string: "https://marked.js.org")),
        Acknowledgement(name: "DOMPurify", role: "Sanitizing rendered Markdown", license: "Apache 2.0 / MPL 2.0", url: URL(string: "https://github.com/cure53/DOMPurify")),
    ]
}

private struct AcknowledgementRow: View {
    @Environment(\.thubanTheme) private var theme
    var item: Acknowledgement

    var body: some View {
        HStack(alignment: .center, spacing: 12.z) {
            VStack(alignment: .leading, spacing: 2.z) {
                Text(item.name)
                    .font(ThubanFont.body(14, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                Text(item.role)
                    .font(ThubanFont.small)
                    .foregroundStyle(theme.inkDimColor)
            }
            Spacer(minLength: 12)
            Chip(item.license, kind: .neutral)
            if let url = item.url {
                Button("Website") { NSWorkspace.shared.open(url) }
                    .buttonStyle(GhostButtonStyle(height: 26, tinted: true, horizontalPadding: 8))
                    .accessibilityLabel("Open the \(item.name) website")
            }
        }
        .padding(.horizontal, 16.z)
        .padding(.vertical, 10.z)
        .accessibilityElement(children: .contain)
    }
}
