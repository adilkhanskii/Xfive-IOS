import SwiftUI

enum X5Style {
    static let blue = Color(red: 0.705, green: 1.00, blue: 0.00)
    static let blueSoft = Color(red: 0.84, green: 1.00, blue: 0.22)
    static let backgroundBlue = Color(red: 0.04, green: 0.28, blue: 0.62)
    static let backgroundCyan = Color(red: 0.00, green: 0.68, blue: 0.92)
    static let ink = Color(red: 0.003, green: 0.005, blue: 0.010)

    static func glassStroke(_ opacity: Double = 0.22) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(opacity),
                Color.white.opacity(0.055),
                blue.opacity(0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct X5LogoMark: View {
    var size: CGFloat = 56

    var body: some View {
        Image("X5PremiumLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size * 2.55, height: size * 1.2)
            .shadow(color: X5Style.blueSoft.opacity(0.46), radius: size * 0.24, x: 0, y: 0)
    }
}

private struct X5ClearGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let highlight: Double

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.34))
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(min(highlight, 0.08)),
                                Color.white.opacity(0.018),
                                X5Style.blue.opacity(0.13)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.055),
                                X5Style.blueSoft.opacity(0.36)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
            .shadow(color: X5Style.blue.opacity(0.16), radius: 12, x: 0, y: 0)
    }
}

private struct X5ClearGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.36))
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.075),
                                Color.white.opacity(0.018),
                                X5Style.blue.opacity(0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                Color.white.opacity(0.055),
                                X5Style.blueSoft.opacity(0.42)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.46), radius: 18, x: 0, y: 8)
            .shadow(color: X5Style.blue.opacity(0.18), radius: 12, x: 0, y: 0)
    }
}

extension View {
    func x5ClearGlass(cornerRadius: CGFloat = 18, highlight: Double = 0.13) -> some View {
        modifier(X5ClearGlassModifier(cornerRadius: cornerRadius, highlight: highlight))
    }

    func x5ClearGlassCircle() -> some View {
        modifier(X5ClearGlassCircleModifier())
    }
}
