import SwiftUI

/// Telegram-inspired chat backdrop. Two layers:
///
/// 1. Multi-stop angular/radial gradient — dark navy → deep purple → teal
///    accent. Mimics the depth Telegram dark wallpapers have without an
///    asset bundle.
/// 2. Canvas pattern overlay drawn at two scales (large sparse + small
///    dense) so it feels generative instead of a tiled grid.
///
/// Pure SwiftUI Canvas, no PNG, scales to any device, dark-mode native.
struct ChatBackground: View {
    /// Symbols rotated through both pattern passes. Light, friendly,
    /// chat / creative motifs that match X5.
    private let glyphs: [String] = [
        "✦", "✧", "✩", "❀", "❁", "❃", "❋",
        "♡", "✿", "❄︎", "✺", "❂", "✻", "❉", "✱"
    ]

    var body: some View {
        ZStack {
            // Layer 1 — gradient base. Two overlapping radial pools give the
            // "Telegram dark wallpaper" depth that a single linear gradient
            // can't reach.
            Color(red: 0.05, green: 0.06, blue: 0.13)
                .ignoresSafeArea()
            RadialGradient(
                colors: [
                    Color(red: 0.18, green: 0.14, blue: 0.36).opacity(0.55),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [
                    Color(red: 0.10, green: 0.30, blue: 0.40).opacity(0.45),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 560
            )
            .ignoresSafeArea()

            // Layer 2 — sparse large glyphs.
            patternCanvas(cellSize: 96, fontSize: 30, opacity: 0.05, salt: 1)
                .ignoresSafeArea()
            // Layer 3 — denser small glyphs, offset to break the grid feel.
            patternCanvas(cellSize: 44, fontSize: 16, opacity: 0.07, salt: 7)
                .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }

    /// One pattern pass. Deterministic per (row, col, salt) so the layers
    /// look stable across redraws but distinct from each other.
    private func patternCanvas(cellSize: CGFloat, fontSize: CGFloat,
                               opacity: Double, salt: Int) -> some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / cellSize)) + 1
            let rows = Int(ceil(size.height / cellSize)) + 2

            for row in 0..<rows {
                for col in 0..<cols {
                    let xOffset: CGFloat = (row % 2 == 0) ? 0 : cellSize / 2
                    let x = CGFloat(col) * cellSize + xOffset
                    let y = CGFloat(row) * cellSize

                    let glyphIndex = (row * 7 + col * 3 + salt) % glyphs.count
                    let rotation = Double((row * 17 + col * 11 + salt * 23) % 360)

                    let text = Text(glyphs[glyphIndex])
                        .font(.system(size: fontSize, weight: .light))
                        .foregroundColor(.white.opacity(opacity))

                    context.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .degrees(rotation))
                        layer.draw(text, at: .zero, anchor: .center)
                    }
                }
            }
        }
    }
}
