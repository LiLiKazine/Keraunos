import SwiftUI
import AVKit
import QuickLook

/// The Library — every finished download. Compact: a searchable list. Regular: a reflowing
/// grid beside a detail pane with an inline player and per-item actions.
struct LibraryScreen: View {
    let model: DownloadViewModel
    @Binding var selection: AppSection
    var onSettings: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(ToastCenter.self) private var toasts
    @State private var search = ""
    @State private var selected: URL?
    @State private var previewURL: URL?
    @State private var pendingDelete: URL?
    /// Selection mode: taps toggle a checkmark instead of playing, and the batch actions appear.
    @State private var isSelecting = false
    @State private var selectedFiles: Set<URL> = []
    @State private var confirmingBatchDelete = false

    private var isRegular: Bool { hSize == .regular }

    private var files: [URL] {
        let all = model.savedFiles
        guard !search.isEmpty else { return all }
        return all.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ZStack {
            Color.Theme.bg.ignoresSafeArea()
            if model.savedFiles.isEmpty {
                emptyState
            } else if isRegular {
                regularLayout
            } else {
                compactLayout
            }
        }
        // Compact puts the batch actions in a bottom bar; regular width has room for them in
        // the detail pane, so it doesn't get one.
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !isRegular {
                SelectionBar(selectedCount: selectedFiles.count,
                             allSelected: allVisibleSelected,
                             onToggleAll: toggleAll,
                             onDelete: { confirmingBatchDelete = true })
            }
        }
        .quickLookPreview($previewURL)
        .deleteConfirmation($pendingDelete, model: model, toasts: toasts)
        .batchDeleteConfirmation(isPresented: $confirmingBatchDelete,
                                 count: selectedFiles.count,
                                 sizeText: model.totalSizeText(Array(selectedFiles)),
                                 onConfirm: deleteSelection)
        .saveMessageToast(model: model, toasts: toasts)
        .task { model.refreshSavedFiles() }
        .onChange(of: model.savedFiles) { _, files in
            // Keep the iPad detail selection valid when its file is deleted elsewhere.
            if let selected, !files.contains(selected) { self.selected = files.first }
            // Drop checkmarks for files that are gone (deleted elsewhere) so a batch action
            // can never target a phantom, and leave selection mode once nothing is left.
            selectedFiles.formIntersection(files)
            if files.isEmpty { endSelecting() }
        }
    }

    // MARK: - Selection mode

    private var selectionTitle: String {
        selectedFiles.isEmpty ? "Select Items" : "\(selectedFiles.count) Selected"
    }

    /// Scoped to the *visible* files so the toggle follows an active search rather than
    /// silently reaching for downloads the user has filtered away.
    private var allVisibleSelected: Bool {
        !files.isEmpty && files.allSatisfy(selectedFiles.contains)
    }

    /// Edit / Done. Shown in the compact header and beside the iPad pane title.
    private var editButton: some View {
        Button(isSelecting ? "Done" : "Edit") {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelecting { endSelecting() } else { isSelecting = true }
            }
        }
        .buttonStyle(.ghost)
    }

    private func toggle(_ file: URL) {
        if selectedFiles.contains(file) { selectedFiles.remove(file) } else { selectedFiles.insert(file) }
    }

    private func toggleAll() {
        if allVisibleSelected { selectedFiles.subtract(files) } else { selectedFiles.formUnion(files) }
    }

    private func endSelecting() {
        isSelecting = false
        selectedFiles = []
    }

    /// Deletes everything selected, then reports the outcome. A partial failure is surfaced in
    /// the toast because Library — unlike Home — has nowhere to show `model.errorMessage`.
    private func deleteSelection() {
        let targets = Array(selectedFiles)
        guard !targets.isEmpty else { return }
        let deleted = model.deleteDownloads(targets)
        withAnimation(.easeInOut(duration: 0.2)) { endSelecting() }
        if deleted < targets.count {
            toasts.show(ToastData(icon: "exclamationmark.triangle", tone: .info,
                                  title: model.errorMessage ?? "Couldn't delete every download."))
        } else {
            toasts.show(ToastData(icon: "trash", tone: .info, title: "Deleted",
                                  subtitle: deleted == 1 ? "1 download" : "\(deleted) downloads"))
        }
    }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // The gear steps aside while selecting — the header belongs to the selection.
                CompactHeader(title: isSelecting ? selectionTitle : "Library",
                              onSettings: isSelecting ? nil : onSettings) { editButton }
                SearchField(text: $search)
                LazyVStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element) { index, file in
                        if index > 0 {
                            Rectangle().fill(Color.Theme.hairline).frame(height: Stroke.hairline)
                        }
                        LibraryRow(
                            title: file.deletingPathExtension().lastPathComponent,
                            subtitle: model.librarySubtitle(file),
                            isSelecting: isSelecting,
                            isSelected: selectedFiles.contains(file),
                            onTap: { if isSelecting { toggle(file) } else { previewURL = file } },
                            menu: { downloadMenuItems(file: file, model: model,
                                                      onPlay: { previewURL = file },
                                                      onDelete: { pendingDelete = file }) }
                        )
                    }
                }
                if files.isEmpty { noMatches }
            }
            .padding(.horizontal, 18)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xxl)
        }
    }

    // MARK: - Regular (iPad): grid + detail pane

    private var regularLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.lg) {
                PaneTitle(title: isSelecting ? selectionTitle : "Library")
                SearchField(text: $search).frame(maxWidth: 280)
                editButton
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.sm)
            gridAndDetail
        }
        .onAppear { if selected == nil { selected = files.first } }
    }

    private var gridAndDetail: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Space.lg)], spacing: Space.lg) {
                    ForEach(files, id: \.self) { file in
                        gridItem(file)
                    }
                }
                .padding(Space.xl)
                if files.isEmpty { noMatches.padding(.top, Space.xxl) }
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(Color.Theme.hairline)

            detailColumn.frame(width: 340)
        }
    }

    /// A grid tile. While selecting, the tap toggles the checkmark and the per-item menu is
    /// suppressed — a long-press action on an unselected file would fight the selection.
    @ViewBuilder private func gridItem(_ file: URL) -> some View {
        if isSelecting {
            tileButton(file)
        } else {
            tileButton(file)
                .downloadContextMenu(file: file, model: model,
                                     onPlay: { selected = file },
                                     onDelete: { pendingDelete = file })
        }
    }

    private func tileButton(_ file: URL) -> some View {
        Button { if isSelecting { toggle(file) } else { selected = file } } label: {
            DownloadTile(title: file.deletingPathExtension().lastPathComponent,
                         subtitle: model.librarySubtitle(file),
                         progress: nil,
                         isSelected: isSelecting ? selectedFiles.contains(file) : selected == file)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        SelectionCheck(isSelected: selectedFiles.contains(file), onCover: true)
                            .padding(Space.sm)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelecting && selectedFiles.contains(file) ? .isSelected : [])
    }

    /// The right-hand column: the player/metadata pane normally, the selection summary and its
    /// batch actions while selecting. `selected` is left untouched so leaving selection mode
    /// restores whatever was being previewed.
    @ViewBuilder private var detailColumn: some View {
        if isSelecting {
            SelectionSummaryPane(count: selectedFiles.count,
                                 sizeText: model.totalSizeText(Array(selectedFiles)),
                                 allSelected: allVisibleSelected,
                                 onToggleAll: toggleAll,
                                 onDelete: { confirmingBatchDelete = true })
        } else {
            DetailPane(file: selected, model: model,
                       onShare: nil,
                       onDelete: { if let selected { pendingDelete = selected } })
        }
    }

    // MARK: - Empty / no-match

    private var emptyState: some View {
        VStack {
            if !isRegular { CompactHeader(title: "Library", onSettings: onSettings).padding(.horizontal, 18).padding(.top, Space.sm) }
            Spacer()
            EmptyStateView(
                symbol: "photo.on.rectangle.angled",
                title: "Nothing here yet",
                message: "Videos you download will show up here, ready to watch offline.")
            Button("Go to Download") { selection = .download }
                .buttonStyle(.ghost)
                .padding(.top, Space.xs)
            Spacer()
            Spacer()
        }
    }

    private var noMatches: some View {
        Text("No downloads match “\(search)”.")
            .font(.Theme.body)
            .foregroundStyle(Color.Theme.text3)
            .frame(maxWidth: .infinity)
            .padding(.top, Space.xl)
    }
}

/// A search field styled as a surface-2 inset (matches the design's rounded search pill).
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color.Theme.text3)
            TextField("Search downloads", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(Color.Theme.text1)
                .tint(Color.Theme.accent)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.Theme.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
    }
}

/// A Library list row: thumbnail, title + metadata, and an ellipsis menu of actions. While
/// selecting it leads with a checkmark and drops the menu — the bottom bar owns the actions.
private struct LibraryRow<Menu: View>: View {
    let title: String
    let subtitle: String
    var isSelecting = false
    var isSelected = false
    let onTap: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onTap) {
                HStack(spacing: 13) {
                    if isSelecting { SelectionCheck(isSelected: isSelected) }
                    Thumbnail(size: CGSize(width: 76, height: 47), cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.Theme.bodyMedium)
                            .foregroundStyle(Color.Theme.text1)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Theme.text3)
                            .tabularNumbers()
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isSelecting {
                SwiftUI.Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.Theme.text3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More actions")
            }
        }
        .padding(.vertical, 12)
        .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
    }
}

/// The iPad right-hand column while selecting: what's selected, how much space it occupies,
/// and the batch actions that compact width puts in its bottom bar.
private struct SelectionSummaryPane: View {
    let count: Int
    let sizeText: String
    let allSelected: Bool
    let onToggleAll: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color.Theme.bg
            VStack(spacing: Space.lg) {
                Spacer()
                if count == 0 {
                    EmptyStateView(symbol: "checkmark.circle",
                                   title: "Nothing selected",
                                   message: "Tap downloads to select them.")
                } else {
                    VStack(spacing: Space.xs) {
                        Text("\(count) selected")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.Theme.text1)
                        Text(sizeText)
                            .font(.Theme.body)
                            .tabularNumbers()
                            .foregroundStyle(Color.Theme.text3)
                    }
                }
                Spacer()
                Button(allSelected ? "Deselect All" : "Select All", action: onToggleAll)
                    .buttonStyle(.secondary)
                Button(action: onDelete) {
                    DetailAction(symbol: "trash",
                                 label: count == 0 ? "Delete" : "Delete \(count)",
                                 tint: Color.Theme.error)
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .opacity(count == 0 ? 0.4 : 1)
            }
            .padding(Space.xl)
        }
    }
}

/// The iPad detail pane: an inline player for the selected file, metadata chips, and actions.
private struct DetailPane: View {
    let file: URL?
    let model: DownloadViewModel
    var onShare: (() -> Void)?
    let onDelete: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.Theme.bg
            if let file {
                content(file)
            } else {
                EmptyStateView(symbol: "play.rectangle",
                               title: "Nothing selected",
                               message: "Pick a download to preview and play it here.")
            }
        }
        .task(id: file) {
            player = file.map { AVPlayer(url: $0) }
        }
    }

    private func content(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))

            Text(file.deletingPathExtension().lastPathComponent)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.Theme.text1)
                .lineLimit(3)

            HStack(spacing: Space.sm) {
                ForEach(metaChips(file), id: \.self) { chip in
                    Text(chip)
                        .font(.system(size: 12))
                        .tabularNumbers()
                        .foregroundStyle(Color.Theme.text2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
                }
            }

            Spacer()

            HStack(spacing: Space.md) {
                ShareLink(item: file) {
                    DetailAction(symbol: "square.and.arrow.up", label: "Share")
                }
                .buttonStyle(.plain)
                if model.canSaveToPhotos(file) {
                    Button { Task { await model.saveToPhotos(file) } } label: {
                        DetailAction(symbol: "square.and.arrow.down", label: "Save")
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onDelete) {
                    DetailAction(symbol: "trash", label: "Delete", tint: Color.Theme.error)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.xl)
    }

    private func metaChips(_ file: URL) -> [String] {
        [model.fileSizeText(file), model.savedDateText(file), model.fileTypeLabel(file)]
            .compactMap { $0 }
    }
}

/// One icon+label action button in the detail pane's action row.
private struct DetailAction: View {
    var symbol: String
    var label: String
    var tint: Color = Color.Theme.text2

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(Color.Theme.hairline, lineWidth: Stroke.hairline))
    }
}
