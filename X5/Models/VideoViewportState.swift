import Foundation

/// Persisted viewport values for a zoomable video player.
///
/// Gesture-specific deltas stay in the view. This state only stores the
/// committed scale and translation, which keeps its behavior deterministic
/// and straightforward to test.
struct VideoViewportState: Equatable {
    static let minimumScale = 1.0
    static let maximumScale = 4.0

    private(set) var scale = minimumScale
    private(set) var translationX = 0.0
    private(set) var translationY = 0.0

    mutating func applyMagnification(
        _ magnification: Double,
        viewportWidth: Double? = nil,
        viewportHeight: Double? = nil
    ) {
        scale = min(max(magnification, Self.minimumScale), Self.maximumScale)

        if scale == Self.minimumScale {
            translationX = 0
            translationY = 0
        } else if let viewportWidth, let viewportHeight {
            clampTranslation(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }
    }

    mutating func applyTranslation(
        x: Double,
        y: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) {
        guard scale > Self.minimumScale else { return }
        let clamped = clampedTranslation(
            x: x,
            y: y,
            scale: scale,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        translationX = clamped.x
        translationY = clamped.y
    }

    mutating func clampTranslation(viewportWidth: Double, viewportHeight: Double) {
        guard scale > Self.minimumScale else {
            translationX = 0
            translationY = 0
            return
        }

        let clamped = clampedTranslation(
            x: translationX,
            y: translationY,
            scale: scale,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        translationX = clamped.x
        translationY = clamped.y
    }

    func clampedTranslation(
        x: Double,
        y: Double,
        scale: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> (x: Double, y: Double) {
        let clampedScale = min(max(scale, Self.minimumScale), Self.maximumScale)
        guard clampedScale > Self.minimumScale else { return (0, 0) }

        let horizontalLimit = max(0, viewportWidth) * (clampedScale - 1) / 2
        let verticalLimit = max(0, viewportHeight) * (clampedScale - 1) / 2
        return (
            min(max(x, -horizontalLimit), horizontalLimit),
            min(max(y, -verticalLimit), verticalLimit)
        )
    }

    mutating func reset() {
        self = VideoViewportState()
    }
}
