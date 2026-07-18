import SwiftUI
import KeraunosCore

struct ContentView: View {
    @State private var cookieStore: CookieStore
    @State private var preferences: Preferences
    @State private var model: DownloadViewModel

    init() {
        let cookieStore = CookieStore()
        let preferences = Preferences()
        _cookieStore = State(initialValue: cookieStore)
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: DownloadViewModel(
            extractor: PythonExtractor(cookieProvider: cookieStore),
            assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
            store: DownloadStore(),
            photoSaver: PhotoLibrarySaver(),
            preferences: preferences))
    }

    var body: some View {
        AppShell(model: model, cookieStore: cookieStore, preferences: preferences)
    }
}

#Preview {
    let cookieStore = CookieStore()
    let preferences = Preferences()
    return AppShell(
        model: DownloadViewModel(
            extractor: MockExtractor(),
            assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
            store: DownloadStore(),
            preferences: preferences),
        cookieStore: cookieStore,
        preferences: preferences)
}
