import AVKit
import SwiftUI
import UniformTypeIdentifiers

private enum LipsyncAudioMode: String, CaseIterable, Identifiable {
    case saved = "Готовая озвучка"
    case text = "Новый текст"
    var id: String { rawValue }
}

private enum LipsyncLanguage: String, CaseIterable, Identifiable {
    case ru, kk, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ru: return "Русский"
        case .kk: return "Қазақша"
        case .en: return "English"
        }
    }
}

struct LipsyncView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser

    @State private var capabilities: AIStudioCapabilities?
    @State private var selectedVideo: AIStudioAsset?
    @State private var selectedAudio: AIStudioAsset?
    @State private var audioMode = LipsyncAudioMode.saved
    @State private var speechText = ""
    @State private var voice = VoiceGenerationVoice.brightHeroine
    @State private var language = LipsyncLanguage.ru
    @State private var speed = 1.0
    @State private var durationSeconds = 5
    @State private var showingVideoPicker = false
    @State private var showingAudioPicker = false
    @State private var importingVideo = false
    @State private var importingAudio = false
    @State private var isUploading = false
    @State private var isWorking = false
    @State private var job: AIStudioAsyncJob?
    @State private var errorMessage: String?
    @State private var player: AVPlayer?

    private let service = AIStudioService()
    private let voiceService = VoiceGenerationService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                header
                providerState
                inputCard
                costCard
                generateButton
                if let job { jobCard(job) }
                if let errorMessage { errorCard(errorMessage) }
            }
            .padding(18)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { X5Background() }
        .navigationTitle("Lipsync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showingVideoPicker) {
            AIAssetPickerView(assetType: "video", title: "Выберите видео") {
                selectedVideo = $0
            }
        }
        .sheet(isPresented: $showingAudioPicker) {
            AIAssetPickerView(assetType: "audio", title: "Выберите озвучку") {
                selectedAudio = $0
            }
        }
        .fileImporter(
            isPresented: $importingVideo,
            allowedContentTypes: [.mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            importFile(result, assetType: "video")
        }
        .fileImporter(
            isPresented: $importingAudio,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            importFile(result, assetType: "audio")
        }
        .task { await loadCapabilities() }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "mouth.fill")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 52, height: 52)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            Text("Точная синхронизация губ")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
            Text("Выберите созданное X5 видео и голос. MiniMax создаст дорожку из текста, а Sync Lipsync синхронизирует её с лицом.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(17)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.12)
    }

    @ViewBuilder
    private var providerState: some View {
        let capability = capabilities?.tool("lipsync")
        if capability?.available == false {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сервис временно недоступен")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(providerReason(capability?.unavailableReason))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("МАТЕРИАЛЫ")
            assetButton(
                title: "Видео",
                value: selectedVideo?.title ?? (selectedVideo == nil ? "Выбрать из облака" : "Видео выбрано"),
                icon: "play.rectangle.fill"
            ) { showingVideoPicker = true }
            uploadButton(title: "Загрузить MP4", icon: "arrow.up.doc") {
                importingVideo = true
            }

            Picker("Источник голоса", selection: $audioMode) {
                ForEach(LipsyncAudioMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if audioMode == .saved {
                assetButton(
                    title: "Аудио",
                    value: selectedAudio?.title ?? "Выбрать из облака",
                    icon: "waveform"
                ) { showingAudioPicker = true }
                uploadButton(title: "Загрузить MP3, WAV или M4A", icon: "arrow.up.doc") {
                    importingAudio = true
                }
            } else {
                TextEditor(text: $speechText)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                Picker("Голос", selection: $voice) {
                    ForEach(VoiceGenerationVoice.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .tint(Color.accentColor)

                Picker("Язык", selection: $language) {
                    ForEach(LipsyncLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Скорость")
                    Slider(value: $speed, in: 0.7...1.2, step: 0.1)
                    Text(String(format: "%.1f×", speed))
                        .foregroundStyle(Color.accentColor)
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            }

            Stepper("Длительность: \(durationSeconds) сек", value: $durationSeconds, in: 1...60)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.08)
        .disabled(isWorking)
    }

    private var costCard: some View {
        VStack(spacing: 9) {
            costRow("Lipsync · \(durationSeconds) сек", value: durationSeconds * 50)
            if audioMode == .text {
                costRow("MiniMax · озвучка", value: VoiceGenerationService.creditCost(for: speechText))
            }
            Divider().overlay(Color.white.opacity(0.1))
            costRow("Итого", value: totalCost, strong: true)
        }
        .padding(15)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.08)
    }

    private var generateButton: some View {
        Button { start() } label: {
            HStack(spacing: 9) {
                if isWorking { ProgressView().tint(.black) }
                else { Image(systemName: "sparkles") }
                Text(isWorking ? "Обрабатываем…" : "Создать за \(totalCost) кредитов")
                    .font(.headline)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(canStart ? Color.accentColor : Color.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
    }

    private func jobCard(_ job: AIStudioAsyncJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(job.status == "completed" ? "Готово" : "Синхронизация")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(job.progress * 100))%")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            ProgressView(value: job.progress).tint(Color.accentColor)
            if let url = job.resultURL {
                VideoPlayer(player: player ?? AVPlayer(url: url))
                    .frame(height: 330)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onAppear {
                        if player == nil { player = AVPlayer(url: url) }
                        player?.play()
                    }
                ShareLink(item: url) {
                    Label("Отправить MP4", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.10)
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
    }

    private func assetButton(title: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.white.opacity(0.5))
                    Text(value).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
            }
            .padding(13)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func uploadButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if isUploading { ProgressView().tint(Color.accentColor) }
                else { Image(systemName: icon).foregroundStyle(Color.accentColor) }
                Text(isUploading ? "Загружаем…" : title)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("до 8 МБ")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isUploading || isWorking)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .black)).tracking(1.2).foregroundStyle(.white.opacity(0.46))
    }

    private func costRow(_ title: String, value: Int, strong: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(strong ? 1 : 0.62))
            Spacer()
            Text("\(value) кредитов").foregroundStyle(strong ? Color.accentColor : Color.white)
        }
        .font(.system(size: 14, weight: strong ? .black : .semibold))
    }

    private var totalCost: Int {
        durationSeconds * 50 + (audioMode == .text ? VoiceGenerationService.creditCost(for: speechText) : 0)
    }

    private var providerAvailable: Bool {
        capabilities?.tool("lipsync").available == true
    }

    private var canStart: Bool {
        !isWorking && !isUploading && providerAvailable && selectedVideo != nil &&
        (audioMode == .saved ? selectedAudio != nil : !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func providerReason(_ code: String?) -> String {
        code == "provider_not_configured"
            ? "Sync Lipsync ещё не подключён к серверу. Запуск и списание кредитов заблокированы."
            : "Провайдер не прошёл последнюю проверку. Запуск и списание кредитов заблокированы."
    }

    private func loadCapabilities() async {
        guard let token = await auth.freshAccessToken() else { return }
        do { capabilities = try await service.capabilities(accessToken: token) }
        catch { errorMessage = error.localizedDescription }
    }

    private func start() {
        guard canStart, let video = selectedVideo, auth.userId != nil else { return }
        guard let profileOperation = currentUser.operationContext() else { return }
        isWorking = true
        errorMessage = nil
        job = nil
        player?.pause()
        player = nil

        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await currentUser.accessTokenForOperation(profileOperation, refresh: {
                await auth.freshAccessToken(minimumValidity: 10 * 60)
            }) else {
                errorMessage = AIStudioServiceError.notAuthenticated.localizedDescription
                return
            }
            do {
                let audioAssetID: String
                if audioMode == .saved, let selectedAudio {
                    audioAssetID = selectedAudio.id
                } else {
                    let voiceResult = try await voiceService.generate(
                        text: speechText,
                        voice: voice,
                        stability: .balanced,
                        speed: speed,
                        languageCode: language.rawValue,
                        requestID: UUID().uuidString.lowercased(),
                        accessToken: token
                    )
                    guard let id = voiceResult.assetID else { throw AIStudioServiceError.invalidResponse }
                    audioAssetID = id
                    guard currentUser.isCurrent(profileOperation) else { return }
                    currentUser.applyCreditsRemaining(voiceResult.creditsRemaining, for: profileOperation)
                }
                var current = try await service.startLipsync(
                    videoAssetID: video.id,
                    audioAssetID: audioAssetID,
                    durationSeconds: durationSeconds,
                    requestID: UUID().uuidString.lowercased(),
                    accessToken: token
                )
                guard currentUser.isCurrent(profileOperation) else { return }
                job = current
                if let remaining = current.creditsRemaining { currentUser.applyCreditsRemaining(remaining, for: profileOperation) }
                for _ in 0..<150 {
                    if current.isTerminal { break }
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    guard currentUser.isCurrent(profileOperation) else { return }
                    current = try await service.lipsyncJob(id: current.id, accessToken: token)
                    guard currentUser.isCurrent(profileOperation) else { return }
                    job = current
                }
                if current.status == "completed", let url = current.resultURL {
                    player = AVPlayer(url: url)
                    X5Feedback.success()
                } else if current.isTerminal {
                    throw AIStudioServiceError.server(status: 503, code: current.errorCode, message: nil, retryable: true)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                X5Feedback.warning()
            }
        }
    }

    private func importFile(_ result: Result<[URL], Error>, assetType: String) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return
        }
        isUploading = true
        errorMessage = nil
        Task { @MainActor in
            defer { isUploading = false }
            guard let token = await auth.freshAccessToken(minimumValidity: 10 * 60) else {
                errorMessage = AIStudioServiceError.notAuthenticated.localizedDescription
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let mimeType = try importedMIMEType(url: url, assetType: assetType)
                let asset = try await service.uploadAsset(
                    data: data,
                    mimeType: mimeType,
                    assetType: assetType,
                    title: url.deletingPathExtension().lastPathComponent,
                    accessToken: token
                )
                if assetType == "video" { selectedVideo = asset }
                else { selectedAudio = asset }
                X5Feedback.success()
            } catch {
                errorMessage = error.localizedDescription
                X5Feedback.warning()
            }
        }
    }

    private func importedMIMEType(url: URL, assetType: String) throws -> String {
        let ext = url.pathExtension.lowercased()
        if assetType == "video", ext == "mp4" { return "video/mp4" }
        if assetType == "audio" {
            switch ext {
            case "mp3": return "audio/mpeg"
            case "wav": return "audio/wav"
            case "m4a", "mp4": return "audio/mp4"
            default: break
            }
        }
        throw AIStudioServiceError.server(
            status: 400,
            code: "unsupported_media",
            message: "Поддерживаются MP4 для видео и MP3, WAV или M4A для аудио.",
            retryable: false
        )
    }
}
