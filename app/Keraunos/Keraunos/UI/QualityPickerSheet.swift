import SwiftUI
import KeraunosCore

/// The quality chooser: a selectable list of resolutions with a Download / Cancel footer.
/// Presented as a bottom sheet on iPhone and a centered form sheet on iPad. Options carry
/// only what the extractor gives us (height, codec, approx size) — nothing is invented.
struct QualityPickerSheet: View {
    let options: [FormatOption]
    let onSelect: (FormatOption) -> Void
    let onCancel: () -> Void

    @State private var selectedID: String?

    private var recommended: FormatOption? { DownloadViewModel.bestOption(options) }
    private var selected: FormatOption? {
        options.first { $0.formatID == selectedID } ?? recommended
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose quality")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.Theme.text1)
                .padding(.top, Space.sm)
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(options, id: \.formatID) { option in
                        Button {
                            selectedID = option.formatID
                        } label: {
                            QualityOptionRow(
                                option: option,
                                isRecommended: option.formatID == recommended?.formatID,
                                isSelected: option.formatID == selected?.formatID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Space.md)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: Space.md) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Button {
                    if let selected { onSelect(selected) }
                } label: {
                    Text(selected.map { "Download \(Self.resolutionLabel($0))" } ?? "Download")
                }
                .buttonStyle(.primary)
            }
            .padding(.top, Space.md)
        }
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.xl)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.Theme.surface1)
        .presentationCornerRadius(Radius.sheet)
        .onAppear { selectedID = recommended?.formatID }
    }

    static func resolutionLabel(_ option: FormatOption) -> String {
        option.height <= 0 ? "Audio" : "\(option.height)p"
    }
}

/// One row in the quality sheet: resolution (+ 4K / Recommended tags), codec, size, check.
private struct QualityOptionRow: View {
    let option: FormatOption
    let isRecommended: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.sm) {
                    Text(QualityPickerSheet.resolutionLabel(option))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.Theme.text1)
                    if option.height >= 2160 {
                        Text("4K").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.Theme.bg)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.Theme.text2, in: RoundedRectangle(cornerRadius: 5))
                    }
                    if isRecommended {
                        Text("Recommended").font(.system(size: 9.5, weight: .bold))
                            .textCase(.uppercase).tracking(0.4)
                            .foregroundStyle(Color.Theme.accent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !option.codecLabel.isEmpty {
                    Text(option.codecLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Theme.text3)
                }
            }
            Spacer(minLength: Space.sm)
            if let bytes = option.approxBytes {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 13)).tabularNumbers()
                    .foregroundStyle(Color.Theme.text2)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.Theme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}
