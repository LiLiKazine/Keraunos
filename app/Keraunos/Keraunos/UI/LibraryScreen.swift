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
        .quickLookPreview($previewURL)
        .deleteConfirmation($pendingDelete, model: model, toasts: toasts)
        .saveMessageToast(model: model, toasts: toasts)
        .task { model.refreshSavedFiles() }
        .onChange(of: model.savedFiles) { _, files in
            // Keep the iPad detail selection valid when its file is deleted elsewhere.
            if let selected, !files.contains(selected) { self.selected = files.first }
        }
    }

    // MARK: - Compact (iPhone)

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                CompactHeader(title: "Library", onSettings: onSettings)
                SearchField(text: $search)
                LazyVStack(spacing: 0) {
                    ForEach(Array(files.enumerated()), id: \.element) { index, file in
                        if index > 0 {
                            Rectangle().fill(Color.Theme.hairline).frame(height: Stroke.hairline)
                        }
                        LibraryRow(
                            title: file.deletingPathExtension().lastPathComponent,
                            subtitle: model.librarySubtitle(file),
                            onTap: { previewURL = file },
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
                PaneTitle(title: "Library")
                SearchField(text: $search).frame(maxWidth: 280)
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
                        Button { selected = file } label: {
                            DownloadTile(title: file.deletingPathExtension().lastPathComponent,
                                         subtitle: model.librarySubtitle(file),
                                         progress: nil,
                                         isSelected: selected == file)
                        }
                        .buttonStyle(.plain)
                        .downloadContextMenu(file: file, model: model,
                                             onPlay: { selected = file },
                                             onDelete: { pendingDelete = file })
                    }
                }
                .padding(Space.xl)
                if files.isEmpty { noMatches.padding(.top, Space.xxl) }
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(Color.Theme.hairline)

            DetailPane(file: selected, model: model,
                       onShare: nil,
                       onDelete: { if let selected { pendingDelete = selected } })
                .frame(width: 340)
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

/// A Library list row: thumbnail, title + metadata, and an ellipsis menu of actions.
private struct LibraryRow<Menu: View>: View {
    let title: String
    let subtitle: String
    let onTap: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onTap) {
                HStack(spacing: 13) {
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
        .padding(.vertical, 12)
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
