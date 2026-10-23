import SwiftUI

/// Premium black background with a controlled blue glow.
/// Apply with `.x5Background()` to any root view.
struct X5Background: View {
    var body: some View {
        ZStack {
            X5Style.ink

            RadialGradient(
                colors: [
                    X5Style.backgroundBlue.opacity(0.24),
                    .clear
                ],
                center: .init(x: 0.5, y: -0.05),
                startRadius: 10,
                endRadius: 430
            )

            RadialGradient(
                colors: [
                    X5Style.backgroundCyan.opacity(0.10),
                    .clear
                ],
                center: .init(x: -0.06, y: 0.34),
                startRadius: 10,
                endRadius: 360
            )

            RadialGradient(
                colors: [
                    X5Style.backgroundCyan.opacity(0.06),
                    .clear
                ],
                center: .init(x: 0.74, y: 0.04),
                startRadius: 4,
                endRadius: 220
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.20),
                    Color.clear,
                    Color.black.opacity(0.36)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Layers the X5Background underneath the receiver.
    func x5Background() -> some View {
        ZStack {
            X5Background()
            self
        }
    }
}
