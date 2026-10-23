import ImageIO
import UIKit

/// Обложки курса и урока из галереи.
///
/// Зачем: фото с камеры — 12–48 Мп. Раньше его перекодировали в JPEG в полном
/// размере, держали в памяти редактора и декодировали `UIImage(data:)` при каждой
/// перерисовке формы → редактор курса «жестко тупил» (Адильхан, сборка 246),
/// а на сервер уходили обложки по 5–10 МБ, которые потом тормозили и у учеников.
/// Обложка на экране не шире ~1200 px, поэтому ужимаем до 1600 px по длинной
/// стороне один раз — сразу после выбора.
enum CourseCoverImage {
    static let maxPixelSize: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.82

    // Готовится в Task.detached и отдаётся в главный поток; после создания
    // не меняется, поэтому передавать между потоками безопасно.
    struct Prepared: @unchecked Sendable {
        let jpeg: Data
        let preview: UIImage
    }

    /// Уменьшенная JPEG-копия + готовая картинка для показа. nil — не картинка.
    /// ImageIO строит уменьшенную копию, не раскрывая полное фото в памяти.
    static func prepare(_ data: Data, maxPixelSize: CGFloat = maxPixelSize) -> Prepared? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Поворот из EXIF (фото «на боку» с камеры) применяем сразу.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: jpegQuality) else { return nil }
        return Prepared(jpeg: jpeg, preview: image)
    }
}
