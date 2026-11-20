#if DEBUG
import SwiftUI
import UIKit

/// Только QA-скрин в симуляторе: настоящий полноэкранный просмотр результата ИИ
/// с кнопкой «Пожаловаться», без входа и сети (X5_AI_REPORT_QA=1).
struct AIReportQAPreview: View {
    static var isOn: Bool { ProcessInfo.processInfo.environment["X5_AI_REPORT_QA"] == "1" }

    var body: some View {
        GeneratedImageViewer(
            asset: GeneratedImageAsset(
                image: UIImage(named: "HomeTrendNanoBanana") ?? UIImage(),
                prompt: "Кроссовки на подиуме, мягкий студийный свет",
                provider: "Nano Banana",
                category: "custom",
                sizeLabel: "3:4",
                costCredits: 40,
                creditsRemaining: nil,
                cloudAssetID: nil
            ),
            onImageUpdated: { _ in },
            onSaveToGallery: { _ in true },
            onRegenerate: { _, _ in }
        )
    }
}
#endif
