import AVKit
import CoreTransferable
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum VideoGenerationPhotoSaveError: LocalizedError {
    case permissionDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Разрешите добавление видео в Фото в настройках iPhone."
        case .saveFailed:
            return "Не удалось сохранить видео в Фото. Попробуйте ещё раз."
        }
    }
}

private enum VideoGenerationStartImagePreparer {
    static func prepareJPEG(fileURL: URL) async throws -> Data {
        let worker = Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            try Task.checkCancellation()
            return try makeJPEG(fileURL: fileURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func makeJPEG(fileURL: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw VideoGenerationServiceError.invalidStartImage
        }

        let compressionQualities: [CGFloat] = [0.88, 0.76, 0.64, 0.50, 0.38]
        var maximumPixelSize = 2_560
        for _ in 0..<7 {
            try Task.checkCancellation()
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                throw VideoGenerationServiceError.invalidStartImage
            }

            for quality in compressionQualities {
                try Task.checkCancellation()
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                ) else {
                    throw VideoGenerationServiceError.invalidStartImage
                }
                CGImageDestinationAddImage(
                    destination,
                    thumbnail,
                    [
                        kCGImageDestinationLossyCompressionQuality: quality
                    ] as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else {
                    throw VideoGenerationServiceError.invalidStartImage
                }
                let data = output as Data
                if data.count <= VideoGenerationService.maxStartImageBytes {
                    return data
                }
            }
            maximumPixelSize = max(320, Int(Double(maximumPixelSize) * 0.72))
        }

        throw VideoGenerationServiceError.startImageTooLarge
    }
}

enum VideoGenerationDisplayState: Equatable {
    case queued
    case rendering
    case completed
    case failed
    case refunded

    init(job: VideoGenerationJob) {
        if job.status == .failed && job.refunded {
            self = .refunded
            return
        }
        switch job.status {
        case .queued: self = .queued
        case .rendering: self = .rendering
        case .completed: self = .completed
        case .failed: self = .failed
        }
    }
}

enum VideoStudioMode: String, Hashable {
    case standard
    case cinema
    case vfx

    var navigationTitle: String {
        switch self {
        case .standard: return "Генерация видео"
        case .cinema: return "Cinema Studio"
        case .vfx: return "VFX из фотографии"
        }
    }
}

struct VideoGeneratorView: View {
    @EnvironmentObject private var auth: Auth

    @State private var prompt = ""
    @State private var aspectRatio = "9:16"
    @State private var durationSeconds = 5
    private let model: VideoGenerationModel = .seedance20Fast
    @State private var resolution: VideoGenerationResolution = .hd
    @State private var generateAudio = true
    @State private var cinemaStyle = "Кинематографичный реализм"
    @State private var cameraMovement = "Медленный наезд"
    @State private var lighting = "Мягкий студийный свет"
    @State private var vfxEffect = "Оживление портрета"
    @State private var currentJob: VideoGenerationJob?
    @State private var recentJobs: [VideoGenerationJob] = []
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    // Галерея через UIKit (X5PhotoPickerPresenter): SwiftUI-шная после Face ID
    // закрывалась и открывалась по кругу (Адильхан 10.10).
    @State private var showingStartImagePicker = false
    @State private var startImagePreview: UIImage?
    @State private var startImage: VideoGenerationStartImage?
    @State private var isPreparingStartImage = false
    @State private var submissionTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var restoreTask: Task<Void, Never>?
    @State private var photoPreparationTask: Task<Void, Never>?
    @State private var lifecycleID = UUID()
    @State private var pollGenerationID = UUID()
    @State private var restoreGenerationID = UUID()
    @State private var photoPreparationID = UUID()
    @State private var isViewActive = false
    @State private var player: AVPlayer?
    @State private var localResultURL: URL?
    @State private var isPreparingResultFile = false
    @State private var isSavingResult = false
    @State private var resultMessage: String?
    @State private var resultPreparationTask: Task<Void, Never>?
    @State private var resultPreparationID = UUID()
    @State private var photoSaveTask: Task<Void, Never>?

    private let service = VideoGenerationService()
    private let resultFileService = VideoGenerationResultFileService()
    private let localStore = VideoGenerationLocalStore()
    private let aspectRatios = ["9:16", "16:9"]
    private let durations = [5, 10]
    let studioMode: VideoStudioMode

    init(studioMode: VideoStudioMode = .standard) {
        self.studioMode = studioMode
    }

    private var availableResolutions: [VideoGenerationResolution] {
        [.standard, .hd]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    promptCard
                    if studioMode != .standard {
                        modeControlsCard
                    }
                    startImageCard
                    settingsCard
                    submitButton

                    if let currentJob {
                        jobCard(currentJob)
                    }

                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 36)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { X5Background() }
            .navigationTitle(studioMode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onDisappear {
                isViewActive = false
                lifecycleID = UUID()
                submissionTask?.cancel()
                submissionTask = nil
                pollTask?.cancel()
                pollTask = nil
                pollGenerationID = UUID()
                restoreTask?.cancel()
                restoreTask = nil
                restoreGenerationID = UUID()
                photoPreparationTask?.cancel()
                photoPreparationTask = nil
                photoPreparationID = UUID()
                resultPreparationTask?.cancel()
                resultPreparationTask = nil
                resultPreparationID = UUID()
                isSubmitting = false
                isPreparingStartImage = false
                discardLocalResult()
            }
            .task(id: auth.userId) {
                beginAccountLifecycle()
                guard let userID = auth.userId else { return }
                let sessionID = lifecycleID
                let generationID = UUID()
                restoreGenerationID = generationID
                let task = Task { @MainActor in
                    await restoreRecentJobs(
                        userID: userID,
                        lifecycleID: sessionID,
                        restoreGenerationID: generationID
                    )
                }
                restoreTask = task
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
                if isRestoreCurrent(
                    sessionID,
                    userID: userID,
                    generationID: generationID
                ) {
                    restoreTask = nil
                }
            }
            .x5SinglePhotoPicker(isPresented: $showingStartImagePicker) { provider in
                beginStartImagePreparation(provider)
            }
            .onChange(of: currentJob?.resultURL) { _ in
                beginResultPreparation(currentJob)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "video.badge.waveform")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 50, height: 50)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Spacer()

                Text("AI VIDEO")
                    .font(.system(size: 11, weight: .black))
                    .tracking(1.2)
                    .foregroundColor(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(headerTitle)
                .font(.system(size: 29, weight: .black))
                .foregroundColor(.white)

            Text(headerSubtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.12)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("СЦЕНА")

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(promptPlaceholder)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.32))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $prompt)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 132)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.clear)
            }
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            )
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.08)
    }

    private var modeControlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(studioMode == .cinema ? "РЕЖИССУРА" : "ЭФФЕКТ")
            if studioMode == .cinema {
                videoOptionMenu(
                    title: "Визуальный стиль",
                    value: $cinemaStyle,
                    values: ["Кинематографичный реализм", "Рекламный премиум", "Документальный", "Неон и sci-fi", "Плёночная драма"],
                    icon: "film.stack"
                )
                videoOptionMenu(
                    title: "Движение камеры",
                    value: $cameraMovement,
                    values: ["Медленный наезд", "Плавный облёт", "Ручная камера", "Статичный кадр", "Долли-зум"],
                    icon: "camera.metering.multispot"
                )
                videoOptionMenu(
                    title: "Свет",
                    value: $lighting,
                    values: ["Мягкий студийный свет", "Контровой закат", "Неоновый свет", "Естественный дневной", "Драматичный низкий ключ"],
                    icon: "light.max"
                )
            } else {
                videoOptionMenu(
                    title: "VFX",
                    value: $vfxEffect,
                    values: ["Оживление портрета", "Параллакс и глубина", "Ветер и движение ткани", "Кинематографичный дождь", "Световые частицы", "Трансформация окружения"],
                    icon: "wand.and.stars"
                )
                Text("VFX честно создаётся как image-to-video: исходная фотография остаётся первым кадром, а выбранный эффект анимирует сцену.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.52))
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.08)
    }

    private func videoOptionMenu(
        title: String,
        value: Binding<String>,
        values: [String],
        icon: String
    ) -> some View {
        Menu {
            ForEach(values, id: \.self) { option in
                Button(option) { value.wrappedValue = option }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundColor(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundColor(.white.opacity(0.46))
                    Text(value.wrappedValue).font(.subheadline.bold()).foregroundColor(.white)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundColor(.white.opacity(0.4))
            }
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private var startImageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("СТАРТОВЫЙ КАДР")
                Spacer()
                Text(studioMode == .vfx ? "ОБЯЗАТЕЛЬНО" : "НЕОБЯЗАТЕЛЬНО")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.34))
            }

            Button { showingStartImagePicker = true } label: {
                HStack(spacing: 10) {
                    if isPreparingStartImage {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "photo.badge.plus")
                    }
                    Text(startImagePreview == nil ? "Выбрать фото" : "Заменить фото")
                        .font(.system(size: 14, weight: .heavy))
                    Spacer()
                    Text("до 8 МБ")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.42))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || isPreparingStartImage)

            if let startImagePreview {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: startImagePreview)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button {
                        photoPreparationTask?.cancel()
                        photoPreparationTask = nil
                        photoPreparationID = UUID()
                        isPreparingStartImage = false
                        self.startImagePreview = nil
                        self.startImage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.68))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }

            Text(
                startImagePreview == nil
                    ? (studioMode == .vfx
                       ? "Для VFX выберите фотографию — эффект будет создан именно из неё."
                       : "Без фото будет создано видео только по описанию.")
                    : "Видео начнётся с выбранного изображения."
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.48))
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.08)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("НАСТРОЙКИ")

            VStack(spacing: 12) {
                settingRow(title: "Модель", systemImage: "sparkles.rectangle.stack") {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(Color.accentColor)
                        Text(model.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Spacer(minLength: 0)
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                settingRow(title: "Формат", systemImage: "aspectratio") {
                    Picker("Формат", selection: $aspectRatio) {
                        ForEach(aspectRatios, id: \.self) { ratio in
                            Text(ratio).tag(ratio)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Color.white.opacity(0.08))

                settingRow(title: "Длительность", systemImage: "timer") {
                    Picker("Длительность", selection: $durationSeconds) {
                        ForEach(durations, id: \.self) { duration in
                            Text("\(duration) сек").tag(duration)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Color.white.opacity(0.08))

                settingRow(title: "Качество", systemImage: "4k.tv") {
                    Picker("Качество", selection: $resolution) {
                        ForEach(availableResolutions) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Color.white.opacity(0.08))

                Toggle(isOn: $generateAudio) {
                    Label("Звук в ролике", systemImage: "speaker.wave.2")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white.opacity(0.82))
                }
                .tint(Color.accentColor)

                Divider().overlay(Color.white.opacity(0.08))

                HStack {
                    Label("Стоимость", systemImage: "creditcard")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white.opacity(0.82))
                    Spacer()
                    Text("≈ \(estimatedCreditCost) кредитов")
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(Color.accentColor)
                }
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.08)
    }

    private var submitButton: some View {
        Button {
            submitVideo()
        } label: {
            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .black))
                }
                Text(
                    isSubmitting
                        ? "Запускаем…"
                        : "Создать за \(estimatedCreditCost)"
                )
                    .font(.system(size: 18, weight: .black))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(canSubmit ? Color.accentColor : Color.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    @ViewBuilder
    private func jobCard(_ job: VideoGenerationJob) -> some View {
        let displayState = VideoGenerationDisplayState(job: job)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                statusIcon(displayState)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle(displayState))
                        .font(.system(size: 18, weight: .black))
                        .foregroundColor(.white)
                    Text(statusSubtitle(displayState))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                }
                Spacer()
            }

            switch displayState {
            case .queued:
                progressView(job.progress)
            case .rendering:
                progressView(job.progress)
            case .completed:
                if let localResultURL, let player {
                    VideoPlayer(player: player)
                        .frame(height: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onAppear { player.play() }

                    HStack(spacing: 10) {
                        ShareLink(item: localResultURL) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        Button {
                            saveResultToPhotos(localResultURL, jobID: job.id)
                        } label: {
                            HStack(spacing: 7) {
                                if isSavingResult {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                }
                                Text(isSavingResult ? "Сохраняем…" : "В Фото")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSavingResult)
                    }
                } else if isPreparingResultFile {
                    HStack(spacing: 10) {
                        ProgressView().tint(Color.accentColor)
                        Text("Готовим видео для просмотра и сохранения…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.66))
                    }
                } else {
                    Button(
                        job.resultURL == nil
                            ? "Обновить результат"
                            : "Обновить и подготовить"
                    ) {
                        beginResultPreparation(job, refreshSignedURL: true)
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.accentColor)
                }
            case .failed, .refunded:
                Button("Повторить") {
                    submitVideo(forceNewIdempotencyKey: true)
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color.accentColor)
            }

            if job.creditsReserved > 0 {
                Text(
                    job.refunded
                        ? "\(job.creditsReserved) кредитов возвращены"
                        : "Зарезервировано \(job.creditsReserved) кредитов"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(job.refunded ? Color.green : .white.opacity(0.44))
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.green)
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.10)
    }

    private func progressView(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: min(max(progress, 0), 1))
                .tint(Color.accentColor)
            Text("\(Int(min(max(progress, 0), 1) * 100))%")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.red.opacity(0.24), lineWidth: 1)
        )
    }

    private func settingRow<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white.opacity(0.82))
            content()
        }
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .black))
            .tracking(1.6)
            .foregroundColor(.white.opacity(0.46))
    }

    private var headerTitle: String {
        switch studioMode {
        case .standard: return "Создайте ролик из идеи"
        case .cinema: return "Соберите сцену как режиссёр"
        case .vfx: return "Оживите фотографию"
        }
    }

    private var headerSubtitle: String {
        switch studioMode {
        case .standard:
            return "Текст → видео и изображение → видео на Seedance. Задача продолжится на сервере, даже если закрыть экран."
        case .cinema:
            return "Сцена, визуальный стиль, движение камеры и свет собираются в один точный промпт Seedance."
        case .vfx:
            return "Выберите фото и эффект. Seedance создаст новое image-to-video, не изменяя готовый ролик."
        }
    }

    private var promptPlaceholder: String {
        switch studioMode {
        case .standard:
            return "Например: премиальная кофейня ночью, медленный пролёт камеры, тёплый свет и пар над чашкой"
        case .cinema:
            return "Опишите сцену, действие героя и окружение"
        case .vfx:
            return "Опишите желаемое движение объекта и окружения"
        }
    }

    private var canSubmit: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
            && !isSubmitting
            && !isPreparingStartImage
            && (studioMode != .vfx || startImage != nil)
    }

    private var effectiveSubmissionPrompt: String {
        let scene = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch studioMode {
        case .standard:
            return scene
        case .cinema:
            return """
            Сцена: \(scene)
            Визуальный стиль: \(cinemaStyle).
            Движение камеры: \(cameraMovement).
            Свет: \(lighting).
            Цельная кинематографичная сцена, естественная анатомия и физика, без водяных знаков и случайного текста.
            """
        case .vfx:
            return """
            Преврати приложенную фотографию в естественное видео.
            Эффект: \(vfxEffect).
            Движение: \(scene)
            Сохрани личность, предметы, композицию и первый кадр. Не добавляй случайный текст, логотипы или новых людей.
            """
        }
    }

    private var estimatedCreditCost: Int {
        durationSeconds == 10 ? 1_200 : 650
    }

    private func beginStartImagePreparation(_ item: NSItemProvider?) {
        photoPreparationTask?.cancel()
        photoPreparationTask = nil
        let preparationID = UUID()
        photoPreparationID = preparationID

        guard let item else {
            startImagePreview = nil
            startImage = nil
            isPreparingStartImage = false
            return
        }

        isPreparingStartImage = true
        errorMessage = nil
        let sessionID = lifecycleID
        photoPreparationTask = Task { @MainActor in
            defer {
                if isPhotoPreparationCurrent(
                    preparationID,
                    lifecycleID: sessionID
                ) {
                    isPreparingStartImage = false
                    photoPreparationTask = nil
                }
            }
            await loadStartImage(
                item,
                preparationID: preparationID,
                lifecycleID: sessionID
            )
        }
    }

    private func beginResultPreparation(
        _ job: VideoGenerationJob?,
        refreshSignedURL: Bool = false
    ) {
        resultPreparationTask?.cancel()
        resultPreparationTask = nil
        resultPreparationID = UUID()
        discardLocalResult()

        guard
            let job,
            let userID = auth.userId,
            isViewActive,
            refreshSignedURL || (job.status == .completed && job.resultURL != nil)
        else {
            return
        }

        let preparationID = UUID()
        resultPreparationID = preparationID
        let sessionID = lifecycleID
        let jobID = job.id
        isPreparingResultFile = true
        errorMessage = nil
        resultPreparationTask = Task { @MainActor in
            defer {
                if isResultPreparationCurrent(
                    preparationID,
                    lifecycleID: sessionID,
                    userID: userID,
                    jobID: jobID
                ) {
                    isPreparingResultFile = false
                    resultPreparationTask = nil
                }
            }
            do {
                let resultURL: URL
                if refreshSignedURL {
                    guard let token = await accessTokenForVideoRequest() else {
                        throw VideoGenerationServiceError.missingAccessToken
                    }
                    try Task.checkCancellation()
                    guard isResultPreparationCurrent(
                        preparationID,
                        lifecycleID: sessionID,
                        userID: userID,
                        jobID: jobID
                    ) else {
                        return
                    }

                    let envelope = try await service.status(
                        jobID: jobID,
                        accessToken: token
                    )
                    try Task.checkCancellation()
                    guard isResultPreparationCurrent(
                        preparationID,
                        lifecycleID: sessionID,
                        userID: userID,
                        jobID: jobID
                    ) else {
                        return
                    }
                    upsertRecentJob(envelope.job)
                    guard envelope.job.status == .completed else {
                        currentJob = envelope.job
                        if envelope.job.status == .queued
                            || envelope.job.status == .rendering {
                            startPolling(
                                jobIDs: [jobID],
                                userID: userID,
                                lifecycleID: sessionID,
                                initialAccessToken: token
                            )
                        }
                        return
                    }
                    guard let freshResultURL = envelope.job.resultURL else {
                        throw VideoGenerationResultFileError.invalidResponse
                    }
                    resultURL = freshResultURL
                } else {
                    guard let existingResultURL = job.resultURL else {
                        throw VideoGenerationResultFileError.invalidResponse
                    }
                    resultURL = existingResultURL
                }

                let localURL = try await resultFileService.prepare(
                    resultURL: resultURL,
                    jobID: jobID
                )
                if Task.isCancelled {
                    resultFileService.cleanup(localURL)
                    return
                }
                guard isResultPreparationCurrent(
                    preparationID,
                    lifecycleID: sessionID,
                    userID: userID,
                    jobID: jobID
                ) else {
                    resultFileService.cleanup(localURL)
                    return
                }
                localResultURL = localURL
                player = AVPlayer(url: localURL)
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard isResultPreparationCurrent(
                    preparationID,
                    lifecycleID: sessionID,
                    userID: userID,
                    jobID: jobID
                ) else {
                    return
                }
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VideoGenerationResultFileError.invalidResponse.localizedDescription
            }
        }
    }

    private func isResultPreparationCurrent(
        _ preparationID: UUID,
        lifecycleID sessionID: UUID,
        userID: String,
        jobID: String
    ) -> Bool {
        isLifecycleCurrent(sessionID, userID: userID)
            && resultPreparationID == preparationID
            && currentJob?.id == jobID
    }

    private func discardLocalResult() {
        let photoSaveOwnsFile = isSavingResult
        player?.pause()
        player = nil
        if !photoSaveOwnsFile {
            resultFileService.cleanup(localResultURL)
        }
        localResultURL = nil
        isPreparingResultFile = false
        resultMessage = nil
    }

    private func saveResultToPhotos(_ url: URL, jobID: String) {
        guard !isSavingResult else { return }
        photoSaveTask?.cancel()
        resultMessage = nil
        isSavingResult = true
        let sessionID = lifecycleID
        photoSaveTask = Task { @MainActor in
            defer {
                if localResultURL != url {
                    resultFileService.cleanup(url)
                }
                isSavingResult = false
                photoSaveTask = nil
            }
            do {
                let authorization = await PHPhotoLibrary.requestAuthorization(
                    for: .addOnly
                )
                guard authorization == .authorized || authorization == .limited else {
                    throw VideoGenerationPhotoSaveError.permissionDenied
                }
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(
                            atFileURL: url
                        )
                    } completionHandler: { success, error in
                        if success {
                            continuation.resume(returning: ())
                        } else {
                            continuation.resume(
                                throwing: error ?? VideoGenerationPhotoSaveError.saveFailed
                            )
                        }
                    }
                }
                try Task.checkCancellation()
                guard lifecycleID == sessionID, currentJob?.id == jobID else {
                    return
                }
                resultMessage = "Видео сохранено в Фото"
            } catch is CancellationError {
                return
            } catch {
                guard lifecycleID == sessionID, currentJob?.id == jobID else {
                    return
                }
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VideoGenerationPhotoSaveError.saveFailed.localizedDescription
            }
        }
    }

    private func loadStartImage(
        _ item: NSItemProvider,
        preparationID: UUID,
        lifecycleID sessionID: UUID
    ) async {
        do {
            guard let pickedURL = try? await PickedPhotoLoader.copyImageFile(
                from: item,
                prefix: "x5-video-start"
            ) else {
                throw VideoGenerationServiceError.invalidStartImage
            }
            let jpegData = try await VideoGenerationStartImagePreparer.prepareJPEG(
                fileURL: pickedURL
            )
            try Task.checkCancellation()
            guard isPhotoPreparationCurrent(
                preparationID,
                lifecycleID: sessionID
            ) else {
                return
            }
            guard let preview = UIImage(data: jpegData) else {
                throw VideoGenerationServiceError.invalidStartImage
            }
            startImage = try VideoGenerationStartImage(
                mimeType: "image/jpeg",
                data: jpegData
            )
            startImagePreview = preview
        } catch is CancellationError {
            return
        } catch {
            guard isPhotoPreparationCurrent(
                preparationID,
                lifecycleID: sessionID
            ) else {
                return
            }
            startImagePreview = nil
            startImage = nil
            errorMessage = safeLocalMessage(for: error)
        }
    }

    private func isPhotoPreparationCurrent(
        _ preparationID: UUID,
        lifecycleID sessionID: UUID
    ) -> Bool {
        isViewActive
            && lifecycleID == sessionID
            && photoPreparationID == preparationID
    }

    private func safeLocalMessage(for error: Error) -> String {
        (error as? VideoGenerationServiceError)?.localizedDescription
            ?? VideoGenerationServiceError.invalidStartImage.localizedDescription
    }

    private func beginAccountLifecycle() {
        submissionTask?.cancel()
        submissionTask = nil
        pollTask?.cancel()
        pollTask = nil
        pollGenerationID = UUID()
        restoreTask?.cancel()
        restoreTask = nil
        restoreGenerationID = UUID()
        photoPreparationTask?.cancel()
        photoPreparationTask = nil
        photoPreparationID = UUID()
        resultPreparationTask?.cancel()
        resultPreparationTask = nil
        resultPreparationID = UUID()
        discardLocalResult()
        isViewActive = true
        lifecycleID = UUID()
        isSubmitting = false
        isPreparingStartImage = false
        startImagePreview = nil
        startImage = nil
        currentJob = nil
        recentJobs = []
        errorMessage = nil
    }

    private func isLifecycleCurrent(_ sessionID: UUID, userID: String) -> Bool {
        isViewActive
            && lifecycleID == sessionID
            && auth.userId == userID
    }

    private func isRestoreCurrent(
        _ sessionID: UUID,
        userID: String,
        generationID: UUID
    ) -> Bool {
        isLifecycleCurrent(sessionID, userID: userID)
            && restoreGenerationID == generationID
    }

    private func accessTokenForVideoRequest(
        forceRefresh: Bool = false
    ) async -> String? {
        if !forceRefresh,
           let token = auth.accessToken?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty,
           !JWTAccessTokenValidity.needsRefresh(
               token,
               minimumValidity: 60
           ) {
            return token
        }
        return await auth.freshAccessToken()
    }

    private func submitVideo(forceNewIdempotencyKey: Bool = false) {
        guard canSubmit else { return }
        guard
            let userID = auth.userId,
            UUID(uuidString: userID) != nil,
            isViewActive
        else {
            errorMessage = VideoGenerationServiceError.missingAccessToken.localizedDescription
            return
        }

        submissionTask?.cancel()
        restoreTask?.cancel()
        restoreTask = nil
        restoreGenerationID = UUID()
        pollTask?.cancel()
        pollTask = nil
        pollGenerationID = UUID()
        resultPreparationTask?.cancel()
        resultPreparationTask = nil
        resultPreparationID = UUID()
        discardLocalResult()
        currentJob = nil
        errorMessage = nil
        isSubmitting = true

        let cleanPrompt = effectiveSubmissionPrompt
        let requestedRatio = aspectRatio
        let requestedDuration = durationSeconds
        let requestedModel = model
        let requestedResolution = resolution
        let requestedGenerateAudio = generateAudio
        let requestedStartImage = startImage
        let fingerprint = VideoGenerationInputFingerprint.make(
            prompt: cleanPrompt,
            aspectRatio: requestedRatio,
            durationSeconds: requestedDuration,
            model: requestedModel,
            resolution: requestedResolution,
            generateAudio: requestedGenerateAudio,
            startImage: requestedStartImage
        )
        let idempotencyKey = localStore.pendingIdempotencyKey(
            for: fingerprint,
            userID: userID,
            forceNew: forceNewIdempotencyKey
        )
        let sessionID = lifecycleID

        submissionTask = Task { @MainActor in
            defer {
                if isLifecycleCurrent(sessionID, userID: userID) {
                    submissionTask = nil
                    isSubmitting = false
                }
            }

            do {
                guard let token = await accessTokenForVideoRequest() else {
                    guard
                        !Task.isCancelled,
                        isLifecycleCurrent(sessionID, userID: userID)
                    else {
                        return
                    }
                    errorMessage = VideoGenerationServiceError.missingAccessToken.localizedDescription
                    return
                }
                try Task.checkCancellation()
                guard isLifecycleCurrent(sessionID, userID: userID) else {
                    return
                }

                let envelope = try await service.submit(
                    prompt: cleanPrompt,
                    aspectRatio: requestedRatio,
                    durationSeconds: requestedDuration,
                    model: requestedModel,
                    resolution: requestedResolution,
                    generateAudio: requestedGenerateAudio,
                    idempotencyKey: idempotencyKey,
                    startImage: requestedStartImage,
                    accessToken: token
                )
                try Task.checkCancellation()
                guard isLifecycleCurrent(sessionID, userID: userID) else {
                    return
                }

                localStore.remember(jobID: envelope.job.id, userID: userID)
                localStore.clearPending(
                    acceptedKey: idempotencyKey,
                    userID: userID
                )
                currentJob = envelope.job
                upsertRecentJob(envelope.job)
                errorMessage = nil

                if envelope.job.status == .queued || envelope.job.status == .rendering {
                    startPolling(
                        jobIDs: activeRecentJobIDs,
                        userID: userID,
                        lifecycleID: sessionID,
                        initialAccessToken: token
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard isLifecycleCurrent(sessionID, userID: userID) else {
                    return
                }
                errorMessage = safeLocalMessage(for: error)
            }
        }
    }

    private func restoreRecentJobs(
        userID: String,
        lifecycleID sessionID: UUID,
        restoreGenerationID generationID: UUID
    ) async {
        guard isRestoreCurrent(
            sessionID,
            userID: userID,
            generationID: generationID
        ) else { return }
        let jobIDs = localStore.recentJobIDs(userID: userID)
        guard !jobIDs.isEmpty else { return }
        guard let token = await accessTokenForVideoRequest() else {
            guard isRestoreCurrent(
                sessionID,
                userID: userID,
                generationID: generationID
            ) else { return }
            startPolling(
                jobIDs: jobIDs,
                userID: userID,
                lifecycleID: sessionID,
                initialAccessToken: nil
            )
            return
        }
        guard
            !Task.isCancelled,
            isRestoreCurrent(
                sessionID,
                userID: userID,
                generationID: generationID
            )
        else {
            return
        }

        var restored: [VideoGenerationJob] = []
        var unresolvedJobIDs: [String] = []
        for jobID in jobIDs {
            if Task.isCancelled { return }
            do {
                let envelope = try await service.status(
                    jobID: jobID,
                    accessToken: token
                )
                guard
                    !Task.isCancelled,
                    isRestoreCurrent(
                        sessionID,
                        userID: userID,
                        generationID: generationID
                    )
                else {
                    return
                }
                restored.append(envelope.job)
            } catch is CancellationError {
                return
            } catch let serviceError as VideoGenerationServiceError
                where serviceError.makesJobUnavailable {
                guard isRestoreCurrent(
                    sessionID,
                    userID: userID,
                    generationID: generationID
                ) else { return }
                localStore.remove(jobID: jobID, userID: userID)
            } catch {
                unresolvedJobIDs.append(jobID)
            }
        }

        guard isRestoreCurrent(
            sessionID,
            userID: userID,
            generationID: generationID
        ) else { return }
        recentJobs = restored
        currentJob = restored.first
        let activeIDs = restored
            .filter { $0.status == .queued || $0.status == .rendering }
            .map(\.id) + unresolvedJobIDs
        if !activeIDs.isEmpty {
            startPolling(
                jobIDs: activeIDs,
                userID: userID,
                lifecycleID: sessionID,
                initialAccessToken: token
            )
        }
    }

    private var activeRecentJobIDs: [String] {
        var ids = recentJobs
            .filter { $0.status == .queued || $0.status == .rendering }
            .map(\.id)
        if let currentJob,
           (currentJob.status == .queued || currentJob.status == .rendering),
           !ids.contains(currentJob.id) {
            ids.insert(currentJob.id, at: 0)
        }
        return ids
    }

    private func upsertRecentJob(_ job: VideoGenerationJob) {
        if let index = recentJobs.firstIndex(where: { $0.id == job.id }) {
            recentJobs[index] = job
        } else {
            recentJobs.insert(job, at: 0)
            recentJobs = Array(
                recentJobs.prefix(VideoGenerationLocalStore.maximumRecentJobCount)
            )
        }
    }

    private func startPolling(
        jobIDs: [String],
        userID: String,
        lifecycleID sessionID: UUID,
        initialAccessToken: String?
    ) {
        guard isLifecycleCurrent(sessionID, userID: userID) else { return }
        var uniqueJobIDs: [String] = []
        var seen = Set<String>()
        for jobID in jobIDs where UUID(uuidString: jobID) != nil {
            if seen.insert(jobID).inserted {
                uniqueJobIDs.append(jobID)
            }
        }
        guard !uniqueJobIDs.isEmpty else { return }
        let preferredJobID = localStore.recentJobIDs(userID: userID).first

        pollTask?.cancel()
        let generationID = UUID()
        pollGenerationID = generationID
        pollTask = Task { @MainActor in
            defer {
                if isLifecycleCurrent(sessionID, userID: userID),
                   pollGenerationID == generationID {
                    pollTask = nil
                }
            }
            var activeJobIDs = uniqueJobIDs
            var accessToken = initialAccessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var authenticationRefreshRequired = false
            var retryAttempt = 0
            while !Task.isCancelled && !activeJobIDs.isEmpty {
                do {
                    try await Task.sleep(
                        nanoseconds: VideoGenerationPollingRetryPolicy
                            .delayNanoseconds(attempt: retryAttempt)
                    )
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                guard isLifecycleCurrent(sessionID, userID: userID) else {
                    return
                }

                let tokenNeedsRefresh = accessToken.map {
                    JWTAccessTokenValidity.needsRefresh(
                        $0,
                        minimumValidity: 60
                    )
                } ?? true
                if authenticationRefreshRequired || tokenNeedsRefresh {
                    let refreshedToken = await accessTokenForVideoRequest(
                        forceRefresh: authenticationRefreshRequired
                    )
                    accessToken = refreshedToken
                    if refreshedToken != nil {
                        authenticationRefreshRequired = false
                    }
                }
                guard let token = accessToken, !token.isEmpty else {
                    guard
                        !Task.isCancelled,
                        isLifecycleCurrent(sessionID, userID: userID)
                    else {
                        return
                    }
                    errorMessage = VideoGenerationServiceError.missingAccessToken.localizedDescription
                    retryAttempt = min(retryAttempt + 1, 3)
                    continue
                }
                guard
                    !Task.isCancelled,
                    isLifecycleCurrent(sessionID, userID: userID)
                else {
                    return
                }

                var stillActive: [String] = []
                var sawSuccessfulStatus = false
                var authenticationFailed = false
                for (index, jobID) in activeJobIDs.enumerated() {
                    do {
                        let envelope = try await service.status(
                            jobID: jobID,
                            accessToken: token
                        )
                        try Task.checkCancellation()
                        guard isLifecycleCurrent(sessionID, userID: userID) else {
                            return
                        }
                        sawSuccessfulStatus = true
                        upsertRecentJob(envelope.job)
                        if currentJob?.id == jobID || preferredJobID == jobID {
                            currentJob = envelope.job
                        }
                        if envelope.job.status == .queued
                            || envelope.job.status == .rendering {
                            stillActive.append(jobID)
                        }
                    } catch is CancellationError {
                        return
                    } catch let serviceError as VideoGenerationServiceError
                        where serviceError.makesJobUnavailable {
                        guard isLifecycleCurrent(sessionID, userID: userID) else {
                            return
                        }
                        localStore.remove(jobID: jobID, userID: userID)
                        recentJobs.removeAll { $0.id == jobID }
                        if currentJob?.id == jobID {
                            currentJob = recentJobs.first
                        }
                        errorMessage = safeLocalMessage(for: serviceError)
                    } catch let serviceError as VideoGenerationServiceError
                        where serviceError.requiresAuthenticationRefresh {
                        guard isLifecycleCurrent(sessionID, userID: userID) else {
                            return
                        }
                        stillActive.append(contentsOf: activeJobIDs[index...])
                        accessToken = nil
                        authenticationRefreshRequired = true
                        authenticationFailed = true
                        errorMessage = safeLocalMessage(for: serviceError)
                        break
                    } catch {
                        guard isLifecycleCurrent(sessionID, userID: userID) else {
                            return
                        }
                        stillActive.append(jobID)
                        errorMessage = safeLocalMessage(for: error)
                    }
                }
                if sawSuccessfulStatus && !authenticationFailed {
                    retryAttempt = 0
                    errorMessage = nil
                } else {
                    retryAttempt = min(retryAttempt + 1, 3)
                }
                activeJobIDs = stillActive
            }
        }
    }

    private func statusIcon(_ status: VideoGenerationDisplayState) -> some View {
        Group {
            switch status {
            case .queued:
                Image(systemName: "clock.fill")
            case .rendering:
                ProgressView().tint(.black)
            case .completed:
                Image(systemName: "checkmark")
            case .failed:
                Image(systemName: "exclamationmark")
            case .refunded:
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .font(.system(size: 18, weight: .black))
        .foregroundColor(.black)
        .frame(width: 42, height: 42)
        .background(
            status == .failed
                ? Color.red
                : status == .refunded ? Color.green : Color.accentColor
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusTitle(_ status: VideoGenerationDisplayState) -> String {
        switch status {
        case .queued: return "В очереди"
        case .rendering: return "Создаём ролик"
        case .completed: return "Видео готово"
        case .failed: return "Не удалось создать"
        case .refunded: return "Кредиты возвращены"
        }
    }

    private func statusSubtitle(_ status: VideoGenerationDisplayState) -> String {
        switch status {
        case .queued: return "Задача сохранена на сервере"
        case .rendering: return "Можно вернуться сюда позже"
        case .completed: return "Ссылка временная — сохраните результат"
        case .failed: return "Повторите попытку"
        case .refunded: return "Списанные кредиты автоматически возвращены"
        }
    }
}
