import SwiftUI

/// A centered, quiet empty state: icon, title (display serif), message, optional action.
struct EmptyState<Actions: View>: View {
    @Environment(\.thubanTheme) private var theme
    var icon: IconName?
    var title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    init(icon: IconName? = nil, title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 10) {
            if let icon {
                Icon(icon, size: 28)
                    .foregroundStyle(theme.brassInkColor)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(ThubanFont.display(20))
                .foregroundStyle(theme.inkColor)
            if let message {
                Text(message)
                    .font(ThubanFont.body(14))
                    .foregroundStyle(theme.inkDimColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            actions()
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(icon: IconName? = nil, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
