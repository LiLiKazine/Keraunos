import SwiftUI

/// The "Refined Native" dark palette. Tokens are authored in oklch in the design
/// system and converted once to sRGB here (SwiftUI has no oklch initializer) — see
/// `docs/superpowers/specs` / the Foundations board for the source values. Restrained
/// chroma, real hairlines, no gradients or glow. Semantic colors are icon tints only.
extension Color {
    enum Theme {
        // Surfaces
        static let bg        = Color(.sRGB, red: 0.0544, green: 0.0607, blue: 0.0709)  // app canvas
        static let surface1  = Color(.sRGB, red: 0.0913, green: 0.1002, blue: 0.1146)  // cards / inputs
        static let surface2  = Color(.sRGB, red: 0.1342, green: 0.1436, blue: 0.1587)  // insets / tracks
        static let hairline  = Color(.sRGB, red: 0.1900, green: 0.1998, blue: 0.2157)  // borders / dividers

        // Text
        static let text1     = Color(.sRGB, red: 0.9417, green: 0.9482, blue: 0.9587)  // primary
        static let text2     = Color(.sRGB, red: 0.6338, green: 0.6459, blue: 0.6654)  // secondary
        static let text3     = Color(.sRGB, red: 0.4660, green: 0.4804, blue: 0.5034)  // captions / meta

        // Accent
        static let accent       = Color(.sRGB, red: 0.3116, green: 0.6191, blue: 0.8948)  // primary actions
        static let accentBright = Color(.sRGB, red: 0.5040, green: 0.7448, blue: 0.9560)  // hover / highlight
        static let accentDim    = Color(.sRGB, red: 0.1970, green: 0.4586, blue: 0.7076)  // pressed
        static let accentSoft    = accent.opacity(0.16)                                    // tinted fills
        static let onAccent     = Color(.sRGB, red: 0.9868, green: 0.9868, blue: 0.9868)  // text/icons on accent

        // Semantic — small icon tints only, never fills
        static let success = Color(.sRGB, red: 0.3057, green: 0.7448, blue: 0.4903)
        static let warning = Color(.sRGB, red: 0.8941, green: 0.7163, blue: 0.3144)
        static let error   = Color(.sRGB, red: 0.8808, green: 0.3507, blue: 0.3331)
    }
}
