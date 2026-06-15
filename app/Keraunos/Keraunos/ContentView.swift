import SwiftUI
import KeraunosCore

struct ContentView: View {
    var body: some View {
        // Milestone 1 uses the mock extractor until PythonExtractor is wired in (Task 13).
        DownloadScreen(model: DownloadViewModel(
            extractor: MockExtractor(),
            downloader: Downloader(),
            store: DownloadStore()))
    }
}

#Preview {
    ContentView()
}
