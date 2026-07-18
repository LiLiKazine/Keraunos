import SwiftUI

/// The app's top-level destinations. Download/Library/Accounts are the tab bar (compact)
/// and sidebar (regular); Settings sits behind the gear (compact) or sidebar footer (regular).
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case download, library, accounts, settings

    var id: String { rawValue }

    /// The three primary destinations shown as tabs / main sidebar items.
    static var primary: [AppSection] { [.download, .library, .accounts] }

    var title: String {
        switch self {
        case .download: "Download"
        case .library:  "Library"
        case .accounts: "Accounts"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .download: "arrow.down.to.line"
        case .library:  "square.grid.2x2"
        case .accounts: "person.crop.circle"
        case .settings: "gearshape"
        }
    }
}
