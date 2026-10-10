import SwiftUI
import UIKit

/// Адильхан 10.10: «в курсапе не должна работать запись экрана».
/// iOS не даёт запретить запись приложению, но сообщает о ней (`isCaptured`):
/// пока идёт запись, трансляция или повтор экрана — закрываем видео чёрным и ставим на паузу.
/// идея: полная защита — FairPlay DRM в Bunny, тогда запись сама даёт чёрный кадр.
struct ScreenCaptureShield: ViewModifier {
    let onCaptureStarted: () -> Void

    @State private var isCaptured = ScreenCapture.isActive

    func body(content: Content) -> some View {
        content
            .overlay {
                if isCaptured {
                    ZStack {
                        Color.black
                        VStack(spacing: 10) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                            Text("Запись экрана в курсах запрещена")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text("Останови запись — и видео снова будет видно")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    }
                    .ignoresSafeArea()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                refresh()
            }
            .onAppear { refresh() }
    }

    private func refresh() {
        isCaptured = ScreenCapture.isActive
        // Пауза каждый раз, когда запись идёт: так видео не играет «под шторкой».
        if isCaptured { onCaptureStarted() }
    }
}

enum ScreenCapture {
    /// Экран текущей сцены; UIScreen.main устарел с iOS 16.
    static var isActive: Bool {
        let screens = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
        return screens.contains { $0.isCaptured }
    }
}

extension View {
    /// Закрывает видео курса, пока идёт запись экрана.
    func courseScreenCaptureShield(onCaptureStarted: @escaping () -> Void) -> some View {
        modifier(ScreenCaptureShield(onCaptureStarted: onCaptureStarted))
    }
}
