import SwiftUI
import KeraunosCore

struct ContentView: View {
    var body: some View {
        DownloadScreen(model: DownloadViewModel(
            extractor: PythonExtractor(),
            assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
            store: DownloadStore()))
    }
}

#Preview {
    // Preview keeps the mock so the canvas needs no interpreter.
    DownloadScreen(model: DownloadViewModel(
        extractor: MockExtractor(),
        assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
        store: DownloadStore()))
}
