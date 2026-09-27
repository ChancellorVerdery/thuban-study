import StudyGraph
import SwiftUI
import ThubanCore

/// Middle pane: the class's graph on the Thuban Graph engine (fully offline): a 2D and a 3D session, each with its
/// own rows, viewport and camera, shown with the engine's expression list. The header keeps the mode switch, the
/// "Tutor is editing" chip, Reset view and Close. Tutor edits go straight to the sessions (`StudyGraphTools`), so
/// there is nothing to sync.
struct GraphPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    @Bindable var session: ClassSession

    /// Re-evaluates `tutorEditedRecently` while the chip is showing.
    @State private var chipTick = 0

    var body: some View {
        let host = session.graphHost
        VStack(spacing: 0.z) {
            header(host)
            // The list appears once the class's saved graph is in (a few ms), so nothing typed earlier is replaced.
            if host.isLoaded {
                StudyGraphView(host: host)
                    // In a narrow 3D pane the kit's overlays shrink to fit rather than being clipped.
                    .studyGraphTheme(app.theme, paper: app.graphPaperTheme, zoom: host.graphZoom(appZoom: AppZoom.shared.scale))
                    .overlay(alignment: .bottom) {
                        if let error = host.engineError {
                            errorBanner("The graph engine could not start: \(error)")
                        }
                    }
            } else {
                theme.bgColor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.panelColor)
        .onAppear { scheduleChipRefresh(host) }
        .onChange(of: host.tutorEditedAt) { _, _ in
            scheduleChipRefresh(host)
        }
    }

    private func scheduleChipRefresh(_ host: StudyGraphHost) {
        guard host.tutorEditedRecently else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.1))
            chipTick += 1
        }
    }

    // MARK: Header

    /// What one header tier shows. The tiers drop, in order: the labelled "Reset view" (→ icon), the title and the
    /// long chip text, the mode icon (list and reset move into a "More" menu), the segment icons, the chip text (its
    /// dot stays), and last the 2D | 3D switch itself (into the menu; the mode icon shows the mode). The close
    /// button sits outside the tiers and is never squeezed or clipped.
    private struct Tier {
        var title = false
        var modeIcon = false
        var chipText: String? = "Editing"
        var resetText = false
        var overflow = false
        var segmentIcons = true
        var modeInMenu = false
    }

    private static let tiers: [Tier] = [
        Tier(title: true, modeIcon: true, chipText: "Tutor is editing", resetText: true),
        Tier(title: true, modeIcon: true, chipText: "Tutor is editing"),
        Tier(modeIcon: true),
        Tier(overflow: true),
        Tier(overflow: true, segmentIcons: false),
        Tier(chipText: nil, overflow: true, segmentIcons: false),
        Tier(modeIcon: true, chipText: nil, overflow: true, modeInMenu: true),
    ]

    private func header(_ host: StudyGraphHost) -> some View {
        let editing = host.tutorEditedRecently
        return HStack(spacing: 6.z) {
            ViewThatFits(in: .horizontal) {
                ForEach(Self.tiers.indices, id: \.self) { index in
                    headerRow(host, editing: editing, tier: Self.tiers[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(glyph: .close, label: "Close graph", size: 28, iconSize: 14) {
                session.showGraph = false
            }
            .fixedSize()
        }
        .padding(.horizontal, 12.z)
        .frame(height: ThubanMetrics.sectionBarHeight)
        .thubanHairline(.bottom, color: theme.lineColor)
        .animation(.easeInOut(duration: 0.15), value: editing)
    }

    private func headerRow(_ host: StudyGraphHost, editing: Bool, tier: Tier) -> some View {
        HStack(spacing: tier.title ? 10 : 8) {
            if tier.modeIcon {
                Icon(session.graphMode == .threeD ? .graph3D : .graph2D, size: 18)
                    .foregroundStyle(theme.brassInkColor)
            }
            if tier.title {
                Text("Graph")
                    .font(ThubanFont.display(16))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !tier.modeInMenu {
                SegmentedPicker(selection: $session.graphMode, options: [
                    SegmentOption(.twoD, "2D", icon: tier.segmentIcons ? .graph2D : nil),
                    SegmentOption(.threeD, "3D", icon: tier.segmentIcons ? .graph3D : nil),
                ], segmentHeight: 24)
                    .fixedSize()
            }
            if editing {
                Group {
                    if let chipText = tier.chipText {
                        Chip(chipText, kind: .accent, dot: true)
                    } else {
                        Circle()
                            .fill(theme.brassInkColor)
                            .frame(width: 8.z, height: 8.z)
                            .help("Tutor is editing")
                    }
                }
                .fixedSize()
                .id(chipTick)
                .transition(.opacity)
                .accessibilityLabel("Tutor is editing")
            }
            Spacer(minLength: 4)
            let listLabel = host.isListShown ? "Hide expression list" : "Show expression list"
            if tier.overflow {
                Menu {
                    if tier.modeInMenu {
                        Picker("Graph", selection: $session.graphMode) {
                            Text("2D graph").tag(GraphMode.twoD)
                            Text("3D graph").tag(GraphMode.threeD)
                        }
                        .pickerStyle(.inline)
                        Divider()
                    }
                    Button(listLabel) { host.toggleList() }
                    Button("Reset view") { host.resetView() }
                } label: {
                    // A macOS menu label draws only text and images (a custom shape would not show).
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13.z, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(theme.inkDimColor)
                .frame(width: 28.z, height: 28.z)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More graph actions")
            } else {
                IconButton(.equations, label: listLabel, size: 28, iconSize: 15, tinted: host.isListShown) { host.toggleList() }
                if tier.resetText {
                    Button("Reset view") { host.resetView() }
                        .buttonStyle(GhostButtonStyle(height: 28, horizontalPadding: 8))
                        .fixedSize()
                } else {
                    IconButton(glyph: .reset, label: "Reset view", size: 28, iconSize: 15) { host.resetView() }
                }
            }
        }
    }

    // MARK: Notices

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(ThubanFont.small)
            .foregroundStyle(theme.negTextColor)
            .padding(.horizontal, 10.z)
            .padding(.vertical, 6.z)
            .background(theme.negSoftColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.chipRadius, style: .continuous))
            .padding(12.z)
            .accessibilityLabel("Graph error: \(message)")
    }
}
