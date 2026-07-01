import Foundation

/// Result of phase 1. `.ready` when there is nothing to choose (0–1 muxable heights):
/// download it immediately, no picker. `.choices` when 2+ heights are available: show the
/// picker, then call `resolve(_:option:)` with the user's pick.
public enum FormatListing: Sendable {
    case ready(ResolvedMedia)
    case choices([FormatOption])
}
