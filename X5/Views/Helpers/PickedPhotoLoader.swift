import CoreTransferable
import PhotosUI
import SwiftUI
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

// MARK: - Галерея через UIKit (одно фото)

/// Системная галерея (PHPickerViewController) для одного фото.
///
/// Зачем (Адильхан 10.10, видео: обложка в портфолио и «Фото героя»): галерея
/// мигала, сама перезапускалась («Загрузка…»), снова просила Face ID, и фото
/// не выбиралось. SwiftUI-шный PhotosPicker пересоздаёт галерею, когда экран
/// под ней перерисовывается. Здесь галерея создаётся один раз и на перерисовки
/// не реагирует (updateUIViewController пустой).
/// Доступ к медиатеке не нужен: PHPickerConfiguration без photoLibrary.
/// идея: перевести сюда и референсы (несколько фото), если баг вернётся там.
struct SystemPhotoPicker: UIViewControllerRepresentable {
    /// nil — закрыли галерею без выбора.
    let onPick: (NSItemProvider?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // Нарочно пусто: перерисовка экрана не должна трогать открытую галерею.
        context.coordinator.onPick = onPick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onPick: (NSItemProvider?) -> Void
        private var finished = false

        init(onPick: @escaping (NSItemProvider?) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Делегат может прийти дважды (выбор + закрытие) — берём первый.
            guard !finished else { return }
            finished = true
            onPick(results.first?.itemProvider)
        }
    }
}

extension View {
    /// Галерея для одного фото поверх экрана. Сама закрывается после выбора.
    func x5SinglePhotoPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (NSItemProvider) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            SystemPhotoPicker { provider in
                isPresented.wrappedValue = false
                if let provider { onPick(provider) }
            }
            .ignoresSafeArea()
        }
    }
}

extension PickedPhotoLoader {
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
