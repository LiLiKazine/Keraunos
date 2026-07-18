import SwiftUI

/// A section label with an optional trailing accent action (e.g. "Recent — See all").
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).sectionLabelStyle()
            Spacer()
            trailing()
        }
    }
}
