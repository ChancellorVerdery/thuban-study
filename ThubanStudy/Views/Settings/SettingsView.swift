import SwiftUI
import ThubanCore

/// The Settings window: a 240 pt navigation column on `panel` and a scrolling content column (max width 860).
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var pane: SettingsPane = .appearance

    var body: some View {
        let theme = app.theme
        HStack(spacing: 0.z) {
            SettingsNav(selection: $pane)
            SettingsContent(pane: pane)
        }
        .environment(\.thubanTheme, theme)
        .foregroundStyle(theme.inkColor)
        .frame(minWidth: 760.z, minHeight: 560.z)
        .background(theme.bgColor)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

/// The seven Settings panes, in navigation order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case account = "Claude account"
    case agents = "Agents"
    case grapher = "Grapher"
    case questionBank = "Question bank"
    case storage = "Data & storage"
    case about = "About"

    var id: String { rawValue }

    /// One line under the page title.
    var caption: String {
        switch self {
        case .appearance: return "Mode and color scheme. Colors follow the scheme in every class tab."
        case .account: return "The tutor and the import agent run on your Claude account or an API key."
        case .agents: return "Which models the tutor and the import agent use, and what the tutor may touch."
        case .grapher: return "The Desmos key behind the 2D/3D grapher and the calculator."
        case .questionBank: return "Defaults for generating, regenerating and mastering questions."
        case .storage: return "Everything lives on this Mac. Export it, find it, or start over."
        case .about: return "Thuban Study and the projects it is built on."
        }
    }

    var icon: IconName? {
        switch self {
        case .appearance: return .themePalette
        case .account: return .tutor
        case .agents: return .mathEngine
        case .grapher: return .graph2D
        case .questionBank: return .questionBank
        case .storage: return .importDocs
        case .about: return .thubanMark
        }
    }
}

// MARK: - Navigation column

private struct SettingsNav: View {
    @Environment(\.thubanTheme) private var theme
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 2.z) {
            Text("Settings")
                .font(ThubanFont.display(20))
                .foregroundStyle(theme.inkColor)
                .padding(.horizontal, 12.z)
                .padding(.top, 20.z)
                .padding(.bottom, 14.z)
            ForEach(SettingsPane.allCases) { pane in
                SettingsNavRow(pane: pane, isSelected: pane == selection) { selection = pane }
            }
            Spacer()
        }
        .padding(.horizontal, 12.z)
        .frame(width: 240.z)
        .frame(maxHeight: .infinity)
        .background(theme.panelColor)
        .thubanHairline(.trailing, color: theme.lineColor)
    }
}

private struct SettingsNavRow: View {
    @Environment(\.thubanTheme) private var theme
    var pane: SettingsPane
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9.z) {
                if let icon = pane.icon {
                    Icon(icon, size: 16)
                        .foregroundStyle(isSelected ? theme.brassInkColor : theme.inkFaintColor)
                }
                Text(pane.rawValue)
                    .font(.system(size: 14.z, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.inkColor : theme.inkDimColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10.z)
            .frame(height: 32.z)
            .background(
                isSelected ? theme.panel2Color : (hovering ? theme.panel2Color.opacity(0.6) : .clear),
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(isSelected ? theme.lineColor : .clear, lineWidth: ThubanMetrics.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(pane.rawValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Content column

private struct SettingsContent: View {
    @Environment(\.thubanTheme) private var theme
    var pane: SettingsPane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28.z) {
                VStack(alignment: .leading, spacing: 6.z) {
                    Text(pane.rawValue)
                        .font(ThubanFont.display(28))
                        .foregroundStyle(theme.inkColor)
                    Text(pane.caption)
                        .font(ThubanFont.body(15))
                        .foregroundStyle(theme.inkDimColor)
                }
                switch pane {
                case .appearance: AppearanceSettings()
                case .account: ClaudeAccountSettings()
                case .agents: AgentsSettings()
                case .grapher: GrapherSettings()
                case .questionBank: QuestionBankSettings()
                case .storage: DataSettings()
                case .about: AboutSettings()
                }
            }
            .padding(.vertical, 32.z)
            .padding(.horizontal, 40.z)
            .frame(maxWidth: 860.z, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(pane)
        }
        .background(theme.bgColor)
    }
}

// MARK: - Shared chrome for the panes

/// A titled group: serif 18 heading, optional caption, then the content.
struct SettingsGroup<Content: View>: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    var caption: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10.z) {
            VStack(alignment: .leading, spacing: 4.z) {
                Text(title)
                    .font(ThubanFont.display(18))
                    .foregroundStyle(theme.inkColor)
                if let caption {
                    Text(caption)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settings row inside a panel: label + description on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    @Environment(\.thubanTheme) private var theme
    var title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16.z) {
            VStack(alignment: .leading, spacing: 3.z) {
                Text(title)
                    .font(ThubanFont.body(14, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                if let detail {
                    Text(detail)
                        .font(ThubanFont.small)
                        .foregroundStyle(theme.inkDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 12.z)
    }
}

/// A short status/feedback line under a control (neutral, positive or negative).
struct SettingsNote: View {
    @Environment(\.thubanTheme) private var theme
    enum Tone { case neutral, positive, negative }
    var text: String
    var tone: Tone = .neutral

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(ThubanFont.small)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var color: Color {
        switch tone {
        case .neutral: return theme.inkDimColor
        case .positive: return theme.posTextColor
        case .negative: return theme.negTextColor
        }
    }
}

/// Thuban's text field chrome: `panel` fill, 1 px `line2` border, radius 8, 36 pt tall.
struct ThubanFieldStyle: ViewModifier {
    @Environment(\.thubanTheme) private var theme
    var invalid: Bool = false
    var mono: Bool = false
    /// Design points at 100 % zoom; nil = the standard control height.
    var height: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? ThubanFont.mono(13) : ThubanFont.body(14))
            .foregroundStyle(theme.inkColor)
            .padding(.horizontal, 10.z)
            .frame(height: height?.z ?? ThubanMetrics.buttonHeight)
            .background(theme.panelColor, in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(invalid ? theme.negColor : theme.line2Color, lineWidth: invalid ? 1.5 : ThubanMetrics.hairline)
            )
    }
}

extension View {
    func thubanField(invalid: Bool = false, mono: Bool = false, height: CGFloat? = nil) -> some View {
        modifier(ThubanFieldStyle(invalid: invalid, mono: mono, height: height))
    }
}

/// A bordered danger button: `neg` text and border on `panel`, filled `negSoft` on hover.
struct DangerOutlineButtonStyle: ButtonStyle {
    @Environment(\.thubanTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.z, weight: .semibold))
            .foregroundStyle(theme.negTextColor)
            .padding(.horizontal, 14.z)
            .frame(height: ThubanMetrics.buttonHeight)
            .background(
                configuration.isPressed ? theme.negSoftColor : theme.panelColor,
                in: RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous)
                    .strokeBorder(theme.negColor, lineWidth: ThubanMetrics.hairline)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == DangerOutlineButtonStyle {
    static var thubanDangerOutline: DangerOutlineButtonStyle { DangerOutlineButtonStyle() }
}

/// Thuban's switch: tinted with the accent.
struct ThubanSwitch: View {
    @Environment(\.thubanTheme) private var theme
    var label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(theme.accentColor)
            .accessibilityLabel(label)
    }
}
