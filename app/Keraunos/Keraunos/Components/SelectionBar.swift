import SwiftUI

/// The bar pinned below Library's content while it is in selection mode: a Select All toggle
/// and the destructive batch action, whose label carries the count so what's about to be
/// deleted is never a mystery. Sits in the bottom safe-area inset, above the tab bar.
struct SelectionBar: View {
    let selectedCount: Int
    /// True when every currently-visible download is selected — flips the left button to
    /// "Deselect All". Scoped to the visible set so it follows an active search.
    let allSelected: Bool
    let onToggleAll: () -> Void
    let onDelete: () -> Void

    private var isEmpty: Bool { selectedCount == 0 }

    var body: some View {
        HStack {
            Button(allSelected ? "Deselect All" : "Select All", action: onToggleAll)
                .buttonStyle(.ghost)
            Spacer()
            Button(isEmpty ? "Delete" : "Delete (\(selectedCount))", action: onDelete)
                .buttonStyle(.ghostDestructive)
                .disabled(isEmpty)
                // GhostButtonStyle doesn't read isEnabled, so dim the disabled state here.
                .opacity(isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Color.Theme.surface1
                Rectangle().fill(Color.Theme.hairline).frame(height: Stroke.hairline)
            }
        }
    }
}

/// The selection indicator on a Library row or grid tile. `onCover` darkens behind the glyph
/// so an unselected ring stays visible against a tile's artwork.
struct SelectionCheck: View {
    let isSelected: Bool
    var onCover = false

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isSelected ? Color.Theme.accent : Color.Theme.text3)
            .background(onCover ? Color.black.opacity(0.35) : .clear, in: Circle())
            .accessibilityHidden(true)
    }
}
