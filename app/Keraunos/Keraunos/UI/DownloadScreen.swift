import SwiftUI

struct DownloadScreen: View {
    @State private var model: DownloadViewModel

    init(model: DownloadViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video link") {
                    TextField("https://x.com/…", text: $model.urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await model.startDownload() }
                    } label: {
                        if model.isWorking {
                            HStack { ProgressView(); Text(model.statusText ?? "Working…") }
                        } else {
                            Text("Download")
                        }
                    }
                    .disabled(model.isWorking || model.urlText.isEmpty)
                }

                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section("Downloads") {
                    if model.savedFiles.isEmpty {
                        Text("No downloads yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.savedFiles, id: \.self) { file in
                            Text(file.lastPathComponent)
                        }
                    }
                }
            }
            .navigationTitle("Keraunos")
        }
    }
}
