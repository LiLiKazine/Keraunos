import SwiftUI
import KeraunosCore

struct ContentView: View {
    var body: some View {
        DownloadScreen(model: DownloadViewModel(
            extractor: PythonExtractor(),
            downloader: Downloader(),
            store: DownloadStore()))
    }
}

#Preview {
    // Preview keeps the mock so the canvas needs no interpreter.
    DownloadScreen(model: DownloadViewModel(
        extractor: MockExtractor(),
        downloader: Downloader(),
        store: DownloadStore()))
}
