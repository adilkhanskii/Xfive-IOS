import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Загрузка фото из системной галереи (PhotosPicker). Один путь для генератора
/// обложек («Фото героя», логотип, референсы) и для CourseUP (обложка курса и урока).
///
/// Зачем (Адильхан 09.10: «выбираю фото → Загрузка... → фото не прикрепилось»):
/// раньше везде было `try? item.loadTransferable(type: Data.self)` и молчаливый
/// `return` при любой ошибке. Фото из iCloud («Оптимизация хранилища») сначала
/// скачивается — обрыв сети или таймаут давал nil. Часть фото (HEIC, Live Photo,
/// общая медиатека) не всегда отдаётся как «просто Data». Пользователь видел
/// только, что ничего не произошло.
/// Теперь: файл (запасной путь — Data) → ImageIO ужимает и перекодирует
/// в JPEG (HEIC/PNG → JPEG) вне главного потока, а ошибку показываем текстом.
enum PickedPhotoLoader {
    enum LoadError: LocalizedError {
        case unreadable

        var errorDescription: String? { PickedPhotoLoader.errorText }
    }

    /// Текст ошибки для экрана — всегда по-русски, без технических кодов
    /// (системные ошибки PhotosPicker приходят на английском и непонятны).
    static let errorText = "Не удалось открыть фото. Если оно в iCloud — проверьте интернет или выберите другое фото."

    /// Байты выбранного фото: сначала файлом (как в генераторе видео), если не
    /// вышло — как Data. Файлом надёжнее для больших HEIC и фото из iCloud.
    static func loadData(from item: PhotosPickerItem) async throws -> Data {
        if let file = try? await item.loadTransferable(type: PickedImageFile.self) {
            defer { try? FileManager.default.removeItem(at: file.url) }
            if let data = try? Data(contentsOf: file.url), !data.isEmpty {
                return data
            }
        }
        // Запасной путь: старый способ «просто Data».
        if let data = try await item.loadTransferable(type: Data.self), !data.isEmpty {
            return data
        }
        throw LoadError.unreadable
    }

    /// Готовое фото: уменьшенный JPEG + картинка для показа.
    /// Тяжёлое декодирование — вне главного потока.
    static func loadPrepared(
        from item: PhotosPickerItem,
        maxPixelSize: CGFloat = CourseCoverImage.maxPixelSize
    ) async throws -> CourseCoverImage.Prepared {
        let data = try await loadData(from: item)
        let prepared = await Task.detached(priority: .userInitiated) {
            CourseCoverImage.prepare(data, maxPixelSize: maxPixelSize)
        }.value
        guard let prepared else { throw LoadError.unreadable }
        return prepared
    }
}

/// Фото, полученное файлом. Файл системы живёт только внутри замыкания,
/// поэтому сразу копируем его к себе во временную папку.
/// Та же схема, что VideoGenerationPickedImageFile в генераторе видео (работает в проде).
struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { image in
            SentTransferredFile(image.url)
        } importing: { received in
            let sourceExtension = received.file.pathExtension
            let filename = "x5-picked-photo-\(UUID().uuidString)"
                + (sourceExtension.isEmpty ? "" : ".\(sourceExtension)")
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename, isDirectory: false)
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return Self(url: copyURL)
        }
    }
}

// MARK: - Галерея (PHPicker в окне SwiftUI)

/// Системная галерея (PHPickerViewController) в окне `.sheet`.
///
/// История (Адильхан 10.10):
/// - 13:58 и 18:01 — галерея открывалась, закрывалась и открывалась снова, опять Face ID.
///   Причина: окно `.sheet` висело на СТРОКЕ Form. Face ID меняет отступы экрана,
///   Form пересобирает строки → SwiftUI снимал окно и, раз флаг ещё true, показывал заново.
/// - 255–256: показывали галерею сами через UIKit (поиск верхнего экрана + статический
///   флаг «открыто»). 20:10 на 255 — «поменял обложку — не поменялось»: приложение дважды
///   перезапускалось в профиле, а новых обложек в Storage после 18:00 нет. Если показ
///   хоть раз не удался, флаг залипал, и галерея больше не открывалась до перезапуска.
/// Теперь: окно галереи — обычный `.sheet`, но ТОЛЬКО на корне экрана (NavigationStack /
/// весь экран), никогда на строке Form/List. Тогда пересборка строк его не трогает,
/// а состояние «открыто» держит SwiftUI, залипнуть нечему.
/// Доступ к медиатеке не нужен: PHPickerConfiguration без photoLibrary.
struct SystemPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let filter: PHPickerFilter
    /// [] — закрыли без выбора. Порядок — как выбирал человек.
    let onFinish: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = filter
        configuration.selectionLimit = max(1, limit)
        configuration.preferredAssetRepresentationMode = .current
        // Номера 1, 2, 3 на выбранных — как в WhatsApp, порядок сохраняется.
        if limit > 1 { configuration.selection = .ordered }
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // Нарочно не трогаем галерею: перерисовка экрана не должна её пересоздавать.
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onFinish: ([NSItemProvider]) -> Void
        private var finished = false

        init(onFinish: @escaping ([NSItemProvider]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Делегат может прийти дважды (выбор + закрытие) — берём первый.
            guard !finished else { return }
            finished = true
            onFinish(results.map(\.itemProvider))
        }
    }
}

extension View {
    /// Галерея для одного фото. Вешать на КОРЕНЬ экрана (NavigationStack), не на строку Form.
    func x5SinglePhotoPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (NSItemProvider) -> Void
    ) -> some View {
        x5PhotoPicker(isPresented: isPresented, limit: 1) { providers in
            if let provider = providers.first { onPick(provider) }
        }
    }

    /// Галерея на несколько фото/видео (референсы, чат). onPick не зовём, если ничего
    /// не выбрали. Вешать на КОРЕНЬ экрана, не на строку Form/List (см. SystemPhotoPicker).
    func x5PhotoPicker(
        isPresented: Binding<Bool>,
        limit: Int,
        filter: PHPickerFilter = .images,
        onPick: @escaping ([NSItemProvider]) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            SystemPhotoPicker(limit: limit, filter: filter) { providers in
                isPresented.wrappedValue = false
                if !providers.isEmpty { onPick(providers) }
            }
            .ignoresSafeArea()
        }
    }
}

/// Фото или видео из галереи UIKit: байты + тип файла.
struct PickedMedia {
    let data: Data
    let contentType: UTType

    var isVideo: Bool { contentType.conforms(to: .movie) || contentType.conforms(to: .video) }
    var mimeType: String { contentType.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg") }
    var fileExtension: String { contentType.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg") }
}

extension PickedPhotoLoader {
    /// Видео или фото из галереи UIKit (портфолио «Добавить», чат).
    /// Видео берём файлом: так iCloud-видео докачивается, а не падает.
    static func loadMedia(from provider: NSItemProvider) async throws -> PickedMedia {
        let registered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let movieType = registered.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) })
            ?? (provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie : nil) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: movieType.identifier) { url, _ in
                    // Файл системы живёт только внутри замыкания — читаем сразу.
                    continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
                }
            }
            guard let data, !data.isEmpty else { throw LoadError.unreadable }
            return PickedMedia(data: data, contentType: movieType)
        }
        let imageType = registered.first(where: { $0.conforms(to: .image) }) ?? .jpeg
        return PickedMedia(data: try await loadData(from: provider), contentType: imageType)
    }

    /// Копия фото из галереи UIKit во временный файл (видео-генератор готовит JPEG
    /// из файла). Файл системы живёт только внутри замыкания — копируем сразу там.
    static func copyImageFile(from provider: NSItemProvider, prefix: String) async throws -> URL {
        let type = UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else { throw LoadError.unreadable }
        let copied: URL? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let ext = url.pathExtension
                let copyURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(prefix)-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
                do {
                    try FileManager.default.copyItem(at: url, to: copyURL)
                    continuation.resume(returning: copyURL)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let copied else { throw LoadError.unreadable }
        return copied
    }

    /// Байты фото из галереи UIKit: сначала файлом (надёжнее для HEIC и iCloud),
    /// потом как Data. Файл системы живёт только внутри замыкания — читаем сразу там.
    static func loadData(from provider: NSItemProvider) async throws -> Data {
        let type = UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else { throw LoadError.unreadable }
        let fileData: Data? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }
        if let fileData, !fileData.isEmpty { return fileData }
        let rawData: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        if let rawData, !rawData.isEmpty { return rawData }
        throw LoadError.unreadable
    }

    /// То же, что loadPrepared(from: PhotosPickerItem), но для галереи UIKit.
    static func loadPrepared(
        from provider: NSItemProvider,
        maxPixelSize: CGFloat = CourseCoverImage.maxPixelSize
    ) async throws -> CourseCoverImage.Prepared {
        let data = try await loadData(from: provider)
        let prepared = await Task.detached(priority: .userInitiated) {
            CourseCoverImage.prepare(data, maxPixelSize: maxPixelSize)
        }.value
        guard let prepared else { throw LoadError.unreadable }
        return prepared
    }
}
