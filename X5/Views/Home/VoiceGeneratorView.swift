import AVFoundation
import SwiftUI

private enum VoiceGenerationLanguage: String, CaseIterable, Hashable, Identifiable {
    case automatic = "auto"
    case russian = "ru"
    case kazakh = "kk"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Авто"
        case .russian:
            return "Русский"
        case .kazakh:
            return "Қазақша"
        case .english:
            return "English"
        }
    }

    var requestCode: String? {
        self == .automatic ? nil : rawValue
    }
}

struct VoiceGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser

    @State private var text = ""
    @State private var selectedVoice = VoiceGenerationVoice.brightHeroine
    @State private var selectedStability = VoiceGenerationStability.balanced
    @State private var selectedLanguage = VoiceGenerationLanguage.automatic
    @State private var speed = 1.0
    @State private var isGenerating = false
    @State private var result: VoiceGenerationResult?
    @State private var errorMessage: String?
    @State private var player: AVPlayer?
    @State private var playerURL: URL?
    @State private var isPlaying = false
    @State private var generationTask: Task<Void, Never>?
    @State private var shareTask: Task<Void, Never>?
    @State private var shareFileURL: URL?
    @State private var resultRequestID: String?
    @State private var isPreparingShareFile = false
    @FocusState private var textFocused: Bool

    private let service = VoiceGenerationService()
    private let shareFileService = VoiceGenerationShareFileService()
    private let localStore = VoiceGenerationLocalStore()
    private let cardBlue = Color(red: 0.03, green: 0.20, blue: 0.40)
    private let actionBlue = Color(red: 0.10, green: 0.55, blue: 0.98)
    private let actionCyan = Color(red: 0.13, green: 0.83, blue: 0.94)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    textCard
                    settingsCard
                    creditCard
                    generateButton

                    if let result {
                        resultCard(result)
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
            .navigationTitle("Озвучка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                    .foregroundStyle(actionCyan)
                }
            }
            .task {
                await refreshProfile()
            }
            .onDisappear {
                generationTask?.cancel()
                generationTask = nil
                shareTask?.cancel()
                shareTask = nil
                shareFileService.remove(shareFileURL)
                shareFileURL = nil
                resultRequestID = nil
                isPreparingShareFile = false
                player?.pause()
                player = nil
                playerURL = nil
                isPlaying = false
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(
                            colors: [actionBlue, actionCyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Spacer()

                Text("AI VOICE")
                    .font(.system(size: 11, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(actionCyan)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(actionCyan.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text("Озвучьте любой текст")
                .font(.system(size: 29, weight: .black))
                .foregroundStyle(.white)

            Text("Выберите голос и подачу. Готовую запись можно прослушать или отправить из приложения.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [cardBlue.opacity(0.95), Color.black.opacity(0.56)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .x5ClearGlass(cornerRadius: 22, highlight: 0.11)
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Текст")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .focused($textFocused)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 170)
                    .padding(10)

                if text.isEmpty {
                    Text("Например: Добро пожаловать в Xfive marketing…")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        characterCount > VoiceGenerationService.maxCharacters
                            ? Color.red.opacity(0.72)
                            : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )

            HStack {
                Text("До 5000 символов")
                Spacer()
                Text("\(characterCount) / \(VoiceGenerationService.maxCharacters)")
                    .foregroundStyle(
                        characterCount > VoiceGenerationService.maxCharacters
                            ? Color.red
                            : Color.white.opacity(0.55)
                    )
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.09)
        .disabled(isGenerating)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("Настройки голоса")

            settingRow(title: "Голос", icon: "person.wave.2") {
                Picker("Голос", selection: $selectedVoice) {
                    ForEach(VoiceGenerationVoice.allCases) { voice in
                        Text(voice.title).tag(voice)
                    }
                }
                .labelsHidden()
                .tint(actionCyan)
            }

            Divider().overlay(Color.white.opacity(0.10))

            VStack(alignment: .leading, spacing: 10) {
                Label("Подача", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Picker("Подача", selection: $selectedStability) {
                    ForEach(VoiceGenerationStability.allCases) { stability in
                        Text(stability.title).tag(stability)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider().overlay(Color.white.opacity(0.10))

            settingRow(title: "Язык", icon: "globe") {
                Picker("Язык", selection: $selectedLanguage) {
                    ForEach(VoiceGenerationLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .tint(actionCyan)
            }

            Divider().overlay(Color.white.opacity(0.10))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Скорость", systemImage: "speedometer")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Text(String(format: "%.1f×", speed))
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(actionCyan)
                }
                .foregroundStyle(.white)

                Slider(value: $speed, in: 0.7...1.2, step: 0.1)
                    .tint(actionBlue)
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.09)
        .disabled(isGenerating)
    }

    private var creditCard: some View {
        HStack(spacing: 13) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(actionCyan)
                .frame(width: 42, height: 42)
                .background(actionCyan.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Стоимость")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Text("\(creditCost) кредитов")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(.white)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Баланс")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Text(currentCredits.map { String($0) } ?? "—")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .foregroundStyle(hasEnoughCredits ? actionCyan : Color.red)
            }
        }
        .padding(15)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.08)
    }

    private var generateButton: some View {
        Button {
            generate()
        } label: {
            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .bold))
                }
                Text(generateButtonTitle)
                    .font(.system(size: 16, weight: .black))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: canGenerate
                        ? [actionBlue, actionCyan]
                        : [Color.white.opacity(0.14), Color.white.opacity(0.08)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate)
    }

    private func resultCard(_ result: VoiceGenerationResult) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Озвучка готова")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(.white)
                    Text("\(result.characterCount) символов · \(result.costCredits) кредитов")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(actionCyan)
            }

            HStack(spacing: 12) {
                Button {
                    togglePlayback()
                } label: {
                    Label(
                        isPlaying ? "Пауза" : "Слушать",
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(actionBlue.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)

                if let shareFileURL {
                    ShareLink(item: shareFileURL) {
                        Label("Отправить MP3", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        guard let resultRequestID else { return }
                        prepareShareFile(
                            audioURL: result.audioURL,
                            requestID: resultRequestID
                        )
                    } label: {
                        HStack(spacing: 8) {
                            if isPreparingShareFile {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(
                                isPreparingShareFile
                                    ? "Готовим MP3…"
                                    : "Подготовить MP3"
                            )
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparingShareFile || resultRequestID == nil)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [actionBlue.opacity(0.22), actionCyan.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .x5ClearGlass(cornerRadius: 20, highlight: 0.11)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.red.opacity(0.30), lineWidth: 1)
        )
    }

    private func settingRow<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            content()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .black))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.46))
    }

    private var characterCount: Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    }

    private var creditCost: Int {
        VoiceGenerationService.creditCost(for: text)
    }

    private var currentCredits: Int? {
        currentUser.profile?.credits
    }

    private var hasEnoughCredits: Bool {
        guard let currentCredits else { return false }
        return currentCredits >= creditCost
    }

    private var canGenerate: Bool {
        !isGenerating &&
        auth.userId != nil &&
        (1...VoiceGenerationService.maxCharacters).contains(characterCount) &&
        creditCost > 0 &&
        hasEnoughCredits
    }

    private var generateButtonTitle: String {
        if isGenerating { return "Создаём озвучку…" }
        if currentCredits == nil { return "Загружаем баланс…" }
        if characterCount == 0 { return "Введите текст" }
        if characterCount > VoiceGenerationService.maxCharacters {
            return "Сократите текст"
        }
        if !hasEnoughCredits { return "Недостаточно кредитов" }
        return "Создать за \(creditCost) кредитов"
    }

    private func generate() {
        guard canGenerate, let userID = auth.userId else { return }
        guard let profileOperation = currentUser.operationContext(for: userID) else { return }
        textFocused = false
        player?.pause()
        player = nil
        playerURL = nil
        isPlaying = false
        shareTask?.cancel()
        shareTask = nil
        shareFileService.remove(shareFileURL)
        shareFileURL = nil
        resultRequestID = nil
        isPreparingShareFile = false
        result = nil
        errorMessage = nil
        isGenerating = true

        let requestedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedVoice = selectedVoice
        let requestedStability = selectedStability
        let requestedSpeed = speed
        let requestedLanguage = selectedLanguage.requestCode
        let fingerprint = VoiceGenerationInputFingerprint.make(
            text: requestedText,
            voice: requestedVoice,
            stability: requestedStability,
            speed: requestedSpeed,
            languageCode: requestedLanguage
        )
        let requestID = localStore.pendingRequestID(
            for: fingerprint,
            userID: userID
        )

        generationTask?.cancel()
        generationTask = Task { @MainActor in
            defer {
                isGenerating = false
                generationTask = nil
            }

            guard let token = await currentUser.accessTokenForOperation(profileOperation, refresh: {
                await auth.freshAccessToken(minimumValidity: 5 * 60)
            }) else {
                errorMessage = VoiceGenerationServiceError
                    .missingAccessToken
                    .localizedDescription
                return
            }

            do {
                let response = try await service.generateWithTokenRefresh(
                    text: requestedText,
                    voice: requestedVoice,
                    stability: requestedStability,
                    speed: requestedSpeed,
                    languageCode: requestedLanguage,
                    requestID: requestID,
                    accessToken: token,
                    refreshAccessToken: { rejectedToken in
                        await currentUser.accessTokenForOperation(profileOperation, refresh: {
                            await auth.accessTokenAfterUnauthorized(
                                rejectedAccessToken: rejectedToken,
                                expectedUserId: userID
                            )
                        })
                    }
                )
                try Task.checkCancellation()
                guard currentUser.isCurrent(profileOperation) else { return }
                currentUser.applyCreditsRemaining(response.creditsRemaining, for: profileOperation)
                result = response
                resultRequestID = requestID
                player = AVPlayer(url: response.audioURL)
                playerURL = response.audioURL
                prepareShareFile(
                    audioURL: response.audioURL,
                    requestID: requestID
                )
                localStore.clearPending(
                    acceptedRequestID: requestID,
                    fingerprint: fingerprint,
                    userID: userID
                )
                X5Feedback.success()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VoiceGenerationServiceError.transport.localizedDescription
                X5Feedback.warning()
            }
        }
    }

    private func prepareShareFile(
        audioURL: URL,
        requestID: String
    ) {
        shareTask?.cancel()
        shareTask = nil
        shareFileService.remove(shareFileURL)
        shareFileURL = nil
        isPreparingShareFile = true

        shareTask = Task { @MainActor in
            defer {
                isPreparingShareFile = false
                shareTask = nil
            }

            do {
                let fileURL = try await shareFileService.prepare(
                    audioURL: audioURL,
                    requestID: requestID
                )
                try Task.checkCancellation()
                guard resultRequestID == requestID else {
                    shareFileService.remove(fileURL)
                    return
                }
                shareFileURL = fileURL
                if !isPlaying {
                    player?.pause()
                    player = AVPlayer(url: fileURL)
                    playerURL = fileURL
                }
            } catch is CancellationError {
                return
            } catch {
                guard resultRequestID == requestID else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VoiceGenerationShareFileError.downloadFailed
                        .localizedDescription
            }
        }
    }

    private func togglePlayback() {
        if let shareFileURL,
           playerURL != shareFileURL,
           !isPlaying {
            player?.pause()
            player = AVPlayer(url: shareFileURL)
            playerURL = shareFileURL
        }
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let currentSeconds = player.currentTime().seconds
            let durationSeconds = player.currentItem?.duration.seconds ?? 0
            if durationSeconds.isFinite,
               durationSeconds > 0,
               currentSeconds >= durationSeconds - 0.2 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    private func refreshProfile() async {
        guard
            let userID = auth.userId,
            let token = await auth.freshAccessToken()
        else {
            return
        }
        _ = await currentUser.load(userId: userID, accessToken: token)
    }
}
