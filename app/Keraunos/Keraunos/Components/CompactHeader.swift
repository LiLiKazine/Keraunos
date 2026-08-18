import SwiftUI

/// The in-content screen header used in compact width (iPhone / narrow iPad windows):
/// either the brand lockup (Home) or a large screen title, with an optional Settings gear
/// and an optional leading-of-the-gear accessory (Library's Edit / Done).
/// In regular width the shell's navigation bar supplies the title instead, so this isn't used.
struct CompactHeader<Accessory: View>: View {
    var title: String
    var brand: Bool = false
    var onSettings: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, brand: Bool = false, onSettings: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.brand = brand
        self.onSettings = onSettings
        self.accessory = accessory
    }

    var body: some View {
        HStack {
            if brand {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.Theme.accent)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.Theme.screenTitle)
                        .foregroundStyle(Color.Theme.text1)
                }
            } else {
                Text(title)
                    .font(.Theme.screenTitle)
                    .foregroundStyle(Color.Theme.text1)
            }
            Spacer()
            accessory()
            if let onSettings {
                IconCircleButton(systemImage: "gearshape", accessibilityLabel: "Settings", action: onSettings)
            }
        }
    }
}

/// The in-content pane title used in regular width (iPad), sitting beside the sidebar
/// toggle that `NavigationSplitView` supplies. Matches the design's content-title.
struct PaneTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(Color.Theme.text1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A 38pt circular icon button on surface-2 with a hairline — the header affordance.
struct IconCircleButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Color.Theme.text2)
                .frame(width: 38, height: 38)
                .background(Color.Theme.surface2, in: Circle())
                .overlay(Circle().strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
