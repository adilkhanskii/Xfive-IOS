import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

final class GalleryVideoPickerCompletionGate: @unchecked Sendable {
    private enum State: Equatable {
        case idle
        case loading
        case terminal
    }

    private let lock = NSLock()
    private var state: State = .idle

    @discardableResult
    func beginLoading() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { return false }
        state = .loading
        return true
    }

    @discardableResult
    func finishLoading() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .loading else { return false }
        state = .terminal
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != .terminal else { return false }
        state = .terminal
        return true
    }
}

enum GalleryVideoPickerError: LocalizedError {
    case unreadableSelection
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSelection:
            return "Не удалось прочитать выбранное видео."
        case .importFailed(let details):
            return "Не удалось подготовить видео: \(details)"
        }
    }
}

/// Native Photos picker kept alive until the user actually cancels or picks a
/// video. Unlike a PhotosPicker embedded inside another SwiftUI sheet, moving
/// between “Видео” and “Коллекции” does not change the presentation binding.
struct GalleryVideoPicker: UIViewControllerRepresentable {
    let stagingID: String
    let onResult: @MainActor (Result<CourseGalleryVideo, Error>) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: PHPickerViewController,
        coordinator: Coordinator
    ) {
        coordinator.cancel()
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: GalleryVideoPicker
        private let completionGate = GalleryVideoPickerCompletionGate()

        init(parent: GalleryVideoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                cancel()
                return
            }
            guard completionGate.beginLoading() else { return }

            let provider = result.itemProvider
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier)?.conforms(to: .movie) == true
            } ?? UTType.movie.identifier
            let suggestedName = provider.suggestedName

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
                guard let sourceURL else {
                    let failure: Error = error.map {
                        GalleryVideoPickerError.importFailed($0.localizedDescription)
                    } ?? GalleryVideoPickerError.unreadableSelection
                    Task { @MainActor in
                        self.deliver(.failure(failure), stagedURL: nil)
                    }
                    return
                }

                // PHPicker only guarantees this temporary URL for the lifetime
                // of the completion handler. Copy it before returning so a
                // large video cannot disappear while an async task is queued.
                do {
                    let stagedURL = try CourseVideoStaging.stage(
                        sourceURL: sourceURL,
                        lessonID: self.parent.stagingID
                    )
                    let trimmedName = suggestedName?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let imported = CourseGalleryVideo(
                        fileURL: stagedURL,
                        originalFileName: trimmedName.flatMap { $0.isEmpty ? nil : $0 }
                            ?? sourceURL.lastPathComponent
                    )
                    Task { @MainActor in
                        self.deliver(.success(imported), stagedURL: stagedURL)
                    }
                } catch {
                    Task { @MainActor in
                        self.deliver(.failure(error), stagedURL: nil)
                    }
                }
            }
        }

        @MainActor
        func cancel() {
            guard completionGate.cancel() else { return }
            parent.onCancel()
        }

        @MainActor
        private func deliver(
            _ result: Result<CourseGalleryVideo, Error>,
            stagedURL: URL?
        ) {
            guard completionGate.finishLoading() else {
                CourseVideoStaging.removeIfManaged(stagedURL)
                return
            }
            parent.onResult(result)
        }
    }
}
