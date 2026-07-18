import SwiftUI
import KeraunosCore

struct ContentView: View {
    private let cookieStore = CookieStore()

    var body: some View {
        HomeScreen(
            model: DownloadViewModel(
                extractor: PythonExtractor(cookieProvider: cookieStore),
                assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
                store: DownloadStore(),
                photoSaver: PhotoLibrarySaver()),
            cookieStore: cookieStore)
    }
}

#Preview {
    let cookieStore = CookieStore()
    HomeScreen(
        model: DownloadViewModel(
            extractor: MockExtractor(),
            assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
            store: DownloadStore()),
        cookieStore: cookieStore)
}
