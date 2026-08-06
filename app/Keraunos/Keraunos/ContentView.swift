import SwiftUI
import KeraunosCore

struct ContentView: View {
    @State private var cookieStore: CookieStore
    @State private var preferences: Preferences
    @State private var model: DownloadViewModel
    private let store: DownloadStore

    init() {
        let cookieStore = CookieStore()
        let preferences = Preferences()
        let store = DownloadStore()
        self.store = store
        _cookieStore = State(initialValue: cookieStore)
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: DownloadViewModel(
            extractor: PythonExtractor(cookieProvider: cookieStore),
            store: store,
            photoSaver: PhotoLibrarySaver(),
            preferences: preferences))
    }

    var body: some View {
        AppShell(model: model, cookieStore: cookieStore, preferences: preferences)
            // No-op unless a UI test asked for a seeded Library (and never in Release). The
            // model read the store before this ran, so re-read it once the clip lands.
            .task {
                if await UITestSupport.seedLibraryIfRequested(in: store) {
                    model.refreshSavedFiles()
                }
            }
    }
}

#Preview {
    let cookieStore = CookieStore()
    let preferences = Preferences()
    return AppShell(
        model: DownloadViewModel(
            extractor: MockExtractor(),
            store: DownloadStore(),
            preferences: preferences),
        cookieStore: cookieStore,
        preferences: preferences)
}
