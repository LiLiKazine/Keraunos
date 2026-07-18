import CoreGraphics

/// Spacing scale and corner-radius scale for the "Refined Native" system.
/// One source of truth so screens compose from the same rhythm.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii, keyed by the element they wrap (chip < control < card < tile < sheet).
enum Radius {
    static let chip: CGFloat = 8
    static let control: CGFloat = 12
    static let card: CGFloat = 16
    static let tile: CGFloat = 20
    static let sheet: CGFloat = 22
}

/// Hairline stroke width. A real 1pt line (not a shadow) on the hairline token.
enum Stroke {
    static let hairline: CGFloat = 1
}
