import SwiftUI

/// The action buttons for a finished download, shared by the long-press context menu and
/// the Library row's ellipsis menu so both offer exactly the same options.
@ViewBuilder
func downloadMenuItems(
    file: URL,
    model: DownloadViewModel,
    onPlay: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
    ShareLink(item: file) { Label("Share…", systemImage: "square.and.arrow.up") }
    if model.canSaveToPhotos(file) {
        Button {
            Task { await model.saveToPhotos(file) }
        } label: {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
        }
    }
    Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
    }
}

/// Shared per-download affordances used by both Home (Recent) and Library so the two lists
/// behave identically: a context menu, a delete confirmation, and the save-result toast.
extension View {
    /// Long-press menu for a finished download: Play / Share / Save to Photos / Delete.
    func downloadContextMenu(
        file: URL,
        model: DownloadViewModel,
        onPlay: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        contextMenu {
            downloadMenuItems(file: file, model: model, onPlay: onPlay, onDelete: onDelete)
        }
    }

    /// Destructive delete confirmation (an action sheet), reported via a toast on success.
    func deleteConfirmation(_ item: Binding<URL?>, model: DownloadViewModel, toasts: ToastCenter) -> some View {
        confirmationDialog(
            "Delete download?",
            isPresented: Binding(get: { item.wrappedValue != nil },
                                 set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { file in
            Button("Delete", role: .destructive) {
                let name = file.deletingPathExtension().lastPathComponent
                model.deleteDownload(file)
                toasts.show(ToastData(icon: "trash", tone: .info, title: "Deleted", subtitle: name))
                item.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { item.wrappedValue = nil }
        } message: { file in
            Text("“\(file.deletingPathExtension().lastPathComponent)” will be removed from this device. This can’t be undone.")
        }
    }

    /// Destructive confirmation for a whole selection. The count leads the copy rather than a
    /// filename: a batch has no single name, and with a search filter active a selected file
    /// may not even be on screen — so the number is the only honest description of the target.
    func batchDeleteConfirmation(
        isPresented: Binding<Bool>,
        count: Int,
        sizeText: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            count == 1 ? "Delete download?" : "Delete \(count) downloads?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(count == 1 ? "Delete" : "Delete \(count)", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(count == 1
                 ? "This download (\(sizeText)) will be removed from this device. This can’t be undone."
                 : "\(count) downloads (\(sizeText)) will be removed from this device. This can’t be undone.")
        }
    }

    /// Bridges the view model's one-shot `saveMessage` into a toast (used wherever a
    /// Save-to-Photos action can fire).
    func saveMessageToast(model: DownloadViewModel, toasts: ToastCenter) -> some View {
        onChange(of: model.saveMessage) { _, message in
            guard let message else { return }
            let succeeded = message == "Saved to Photos."
            toasts.show(ToastData(
                icon: succeeded ? "photo.badge.checkmark" : "exclamationmark.triangle",
                tone: succeeded ? .success : .info,
                title: message))
            model.dismissSaveMessage()
        }
    }
}
