import Foundation
import Observation

/// How the app resolves a link that offers more than one quality.
enum DefaultQuality: String, CaseIterable, Sendable {
    case ask, highest
    var label: String {
        switch self {
        case .ask:     "Ask every time"
        case .highest: "Highest available"
        }
    }
}

/// User preferences that genuinely change behavior, persisted in `UserDefaults`.
/// Only settings backed by real behavior live here — the UI never shows a dead switch.
@MainActor @Observable final class Preferences {
    var defaultQuality: DefaultQuality {
        didSet { defaults.set(defaultQuality.rawValue, forKey: Keys.defaultQuality) }
    }
    var autoSaveToPhotos: Bool {
        didSet { defaults.set(autoSaveToPhotos, forKey: Keys.autoSaveToPhotos) }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let defaultQuality = "defaultQuality"
        static let autoSaveToPhotos = "autoSaveToPhotos"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultQuality = defaults.string(forKey: Keys.defaultQuality)
            .flatMap(DefaultQuality.init(rawValue:)) ?? .ask
        self.autoSaveToPhotos = defaults.bool(forKey: Keys.autoSaveToPhotos)
    }
}
