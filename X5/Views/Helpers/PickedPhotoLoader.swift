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

// MARK: - Галерея через UIKit

/// Системная галерея (PHPickerViewController), которую показывает сам UIKit —
/// поверх самого верхнего экрана, мимо SwiftUI.
///
/// Зачем (Адильхан 10.10, видео 13:58 и 18:01–18:05): галерея открывалась,
/// сама закрывалась и открывалась снова, опять просила Face ID, фото не выбиралось.
/// Причина: `.sheet`/`.photosPicker` висели на строке Form/ленивого списка. Face ID
/// и галерея меняют безопасные отступы → Form пересобирает строки → SwiftUI
/// снимает окно галереи и, раз флаг ещё true, показывает заново. По кругу.
/// Сборка 254 убрала только перезагрузку профиля, а пересборка строк осталась.
/// Здесь SwiftUI о галерее не знает: перерисовки её не трогают.
/// Доступ к медиатеке не нужен: PHPickerConfiguration без photoLibrary.
@MainActor
enum X5PhotoPickerPresenter {
    /// Открытая галерея. Держим делегат, пока она не закроется (у picker он weak).
    private static var active: PickerDelegate?

    /// limit — сколько можно выбрать; filter — фото (.images) или фото и видео.
    /// onPick получает [] при закрытии без выбора; порядок — как выбирал человек.
    static func present(
        limit: Int,
        filter: PHPickerFilter = .images,
        onPick: @escaping ([NSItemProvider]) -> Void
    ) {
        // Второй тап, пока галерея открыта, игнорируем — иначе две галереи подряд.
        guard active == nil, let presenter = topViewController() else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = filter
        configuration.selectionLimit = max(1, limit)
        // Номера 1, 2, 3 на выбранных — как в WhatsApp, порядок сохраняется.
        if limit > 1 { configuration.selection = .ordered }
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = PickerDelegate { providers in
            active = nil
            onPick(providers)
        }
        picker.delegate = delegate
        picker.presentationController?.delegate = delegate
        active = delegate
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate,
        UIAdaptivePresentationControllerDelegate {
        private let finish: ([NSItemProvider]) -> Void
        private var finished = false

        init(finish: @escaping ([NSItemProvider]) -> Void) {
            self.finish = finish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            complete(results.map(\.itemProvider))
        }

        /// Закрыли свайпом вниз — галерея могла не вызвать didFinishPicking.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            complete([])
        }

        private func complete(_ providers: [NSItemProvider]) {
            // Делегат может прийти дважды (выбор + закрытие) — берём первый.
            guard !finished else { return }
            finished = true
            finish(providers)
        }
    }
}

// @MainActor: галерею можно показывать только из главного потока.
@MainActor
extension View {
    /// Галерея для одного фото. Флаг сразу сбрасываем: дальше галереей владеет UIKit,
    /// и перерисовка экрана её уже не закроет и не откроет заново.
    func x5SinglePhotoPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (NSItemProvider) -> Void
    ) -> some View {
        x5PhotoPicker(isPresented: isPresented, limit: 1) { providers in
            if let provider = providers.first { onPick(provider) }
        }
    }

    /// Галерея на несколько фото/видео (референсы, чат). onPick не зовём, если ничего не выбрали.
    func x5PhotoPicker(
        isPresented: Binding<Bool>,
        limit: Int,
        filter: PHPickerFilter = .images,
        onPick: @escaping ([NSItemProvider]) -> Void
    ) -> some View {
        onChange(of: isPresented.wrappedValue) { show in
            guard show else { return }
            isPresented.wrappedValue = false
            X5PhotoPickerPresenter.present(limit: limit, filter: filter) { providers in
                if !providers.isEmpty { onPick(providers) }
            }
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
