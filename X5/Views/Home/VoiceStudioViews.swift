import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// Премиум-озвучка: карточки голосов с образцами, «Мои голоса», клон,
// голос по описанию, настройки и теги эмоций. Акцент — салатовый X5Style.blue,
// как у кнопок «Создать»; тапы ≥ 44 pt.

/// Один плеер образцов на экран: новый ▶ останавливает предыдущий.
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    @Published private(set) var playingKey: String?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var tempFile: URL?

    func toggle(key: String, url: URL) {
        if playingKey == key {
            stop()
            return
        }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player = next
        playingKey = key
        next.play()
    }

    /// Превью дизайна приходит байтами — проигрываем через временный mp3.
    func toggle(key: String, audio: Data) {
        if playingKey == key {
            stop()
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-voice-preview-\(key.hashValue.magnitude).mp3")
        guard (try? audio.write(to: url, options: .atomic)) != nil else { return }
        toggle(key: key, url: url)
        tempFile = url
    }

    func stop() {
        player?.pause()
        player = nil
        playingKey = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let tempFile {
            try? FileManager.default.removeItem(at: tempFile)
        }
        tempFile = nil
    }
}

private let studioAccent = X5Style.blue
private let studioInk = X5Style.ink

struct VoiceSoonBadge: View {
    var body: some View {
        Text("скоро")
            .font(.system(size: 10, weight: .black))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
            .foregroundStyle(.white.opacity(0.7))
    }
}

private struct StudioPlayButton: View {
    let isPlaying: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isPlaying ? studioInk : .white)
                .frame(width: 44, height: 44)
                .background(isPlaying ? studioAccent : Color.white.opacity(0.10))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Выбор голоса

struct PremiumVoicePickerView: View {
    let catalog: VoiceStudioCatalog
    let available: Bool
    @Binding var selectedID: String
    let onDelete: (VoiceStudioMyVoice) -> Void
    let onClone: () -> Void
    let onDesign: () -> Void
    @StateObject private var player = VoicePreviewPlayer()

    private var isFull: Bool { catalog.myVoices.count >= catalog.voiceLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(catalog.premade) { voice in
                        premadeCard(voice)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("Мои голоса")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(catalog.myVoices.count)/\(catalog.voiceLimit)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ForEach(catalog.myVoices) { voice in
                myVoiceRow(voice)
            }

            HStack(spacing: 10) {
                addCard(
                    title: "Свой голос",
                    icon: "mic.fill",
                    price: catalog.prices.clone,
                    blockedNote: catalog.cloneAvailable ? nil : "Нужен тариф Starter",
                    action: onClone
                )
                addCard(
                    title: "По описанию",
                    icon: "wand.and.stars",
                    price: catalog.prices.design,
                    action: onDesign
                )
            }
        }
        .onDisappear { player.stop() }
    }

    private func premadeCard(_ voice: VoiceStudioPremadeVoice) -> some View {
        let isSelected = available && selectedID == voice.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(voice.name.prefix(1)))
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(isSelected ? studioAccent : .white)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Spacer()
                if available, let url = voice.previewURL {
                    StudioPlayButton(
                        isPlaying: player.playingKey == voice.id,
                        label: "Прослушать \(voice.name)"
                    ) {
                        player.toggle(key: voice.id, url: url)
                    }
                } else {
                    VoiceSoonBadge()
                }
            }
            Text(voice.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isSelected ? studioAccent : .white)
            Text(voice.gender == "male" ? "Мужской" : "Женский")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(12)
        .frame(width: 136, alignment: .leading)
        .background(isSelected ? studioAccent.opacity(0.10) : Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? studioAccent : Color.white.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
        )
        .opacity(available ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            if available { selectedID = voice.id }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func myVoiceRow(_ voice: VoiceStudioMyVoice) -> some View {
        let isSelected = available && selectedID == voice.id
        return HStack(spacing: 12) {
            Image(systemName: voice.isClone ? "mic.fill" : "wand.and.stars")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(studioAccent)
                .frame(width: 38, height: 38)
                .background(studioAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSelected ? studioAccent : .white)
                    .lineLimit(1)
                Text(voice.isClone ? "Свой голос · клон" : "По описанию")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button {
                onDelete(voice)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить \(voice.name)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 58)
        .background(isSelected ? studioAccent.opacity(0.10) : Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? studioAccent : Color.white.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if available { selectedID = voice.id }
        }
    }

    private func addCard(
        title: String,
        icon: String,
        price: Int,
        blockedNote: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        // blockedNote: действие выключено сервером (клон без тарифа Starter).
        let disabled = !available || isFull || blockedNote != nil
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Image(systemName: icon)
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(studioAccent)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                if !available {
                    VoiceSoonBadge()
                } else {
                    Text(blockedNote ?? (isFull ? "Лимит 3 голоса" : "\(price) кредитов"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        disabled ? Color.white.opacity(0.10) : studioAccent.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
            .opacity(disabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Настройки премиума

struct PremiumVoiceSettings: Equatable {
    static let defaults = PremiumVoiceSettings()

    var speed = 1.0
    var stability = VoiceGenerationStability.balanced
    var style = VoicePremiumOptions.defaultStyle
    var similarityBoost = VoicePremiumOptions.defaultSimilarityBoost
}

struct PremiumVoiceSettingsView: View {
    @Binding var settings: PremiumVoiceSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            slider(
                title: "Скорость",
                hint: "Темп речи",
                value: $settings.speed,
                range: 0.7...1.2,
                step: 0.1,
                display: String(format: "%.1f×", settings.speed),
                left: "0.7×",
                right: "1.2×"
            )
            VStack(alignment: .leading, spacing: 6) {
                header("Стабильность", value: stabilityTitle(settings.stability))
                Text("Меньше — больше эмоций и импровизации, больше — ровнее")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                // eleven_v3 принимает только 0 / 0.5 / 1.
                Picker("Стабильность", selection: $settings.stability) {
                    ForEach(VoiceGenerationStability.allCases) { value in
                        Text(stabilityTitle(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
            slider(
                title: "Эмоциональность",
                hint: "Насколько ярко подавать характер голоса",
                value: $settings.style,
                range: 0...1,
                step: 0.05,
                display: "\(Int((settings.style * 100).rounded()))%",
                left: "0%",
                right: "100%"
            )
            slider(
                title: "Сходство с голосом",
                hint: "Насколько точно держаться оригинального тембра",
                value: $settings.similarityBoost,
                range: 0...1,
                step: 0.05,
                display: "\(Int((settings.similarityBoost * 100).rounded()))%",
                left: "0%",
                right: "100%"
            )
            Button {
                settings = .defaults
            } label: {
                Label("По умолчанию", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(settings == .defaults ? Color.white.opacity(0.35) : Color.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(settings == .defaults)
        }
    }

    private func stabilityTitle(_ value: VoiceGenerationStability) -> String {
        switch value {
        case .expressive: return "Творчески"
        case .balanced: return "Естественно"
        case .stable: return "Стабильно"
        }
    }

    private func header(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(studioAccent)
        }
    }

    private func slider(
        title: String,
        hint: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String,
        left: String,
        right: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title, value: display)
            Text(hint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Slider(value: value, in: range, step: step)
                .tint(studioAccent)
                .accessibilityLabel(title)
            HStack {
                Text(left)
                Spacer()
                Text(right)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Теги эмоций eleven_v3

struct VoiceAudioTag: Identifiable {
    let tag: String
    let title: String
    var id: String { tag }

    static let all = [
        VoiceAudioTag(tag: "[whispers]", title: "шёпот"),
        VoiceAudioTag(tag: "[laughs]", title: "смех"),
        VoiceAudioTag(tag: "[excited]", title: "восторг"),
        VoiceAudioTag(tag: "[sighs]", title: "вздох"),
        VoiceAudioTag(tag: "[sarcastic]", title: "сарказм"),
        VoiceAudioTag(tag: "[curious]", title: "любопытство")
    ]
}

struct VoiceAudioTagChips: View {
    let onInsert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Эмоции в тексте · нажмите — тег встанет в текст")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VoiceAudioTag.all) { item in
                        Button {
                            onInsert(item.tag)
                        } label: {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(studioAccent)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(studioAccent.opacity(0.10))
                                .overlay(Capsule().stroke(studioAccent.opacity(0.30), lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Вставить тег \(item.title)")
                    }
                }
            }
        }
    }
}

// MARK: - Общие куски шторок

private struct StudioPrimaryButton: View {
    let title: String
    let icon: String
    let enabled: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(studioInk)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.system(size: 16, weight: .black))
            .foregroundStyle(enabled ? studioInk : .white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(enabled ? studioAccent : Color.white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

private func studioField(_ placeholder: String, text: Binding<String>) -> some View {
    TextField(placeholder, text: text)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
}

private func studioError(_ message: String?) -> some View {
    Group {
        if let message {
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Свой голос

struct VoiceCloneSheet: View {
    let price: Int
    let accessToken: () async -> String?
    let onCreated: (VoiceStudioMyVoice, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case record = "Записать"
        case upload = "Загрузить файл"
        var id: String { rawValue }
    }

    @StateObject private var recorder = AudioRecorder(sampleRate: 44_100, bitRate: 128_000)
    @StateObject private var player = VoicePreviewPlayer()
    @State private var mode = Mode.record
    @State private var name = ""
    @State private var consent = false
    @State private var audio: (data: Data, mime: String, ext: String)?
    @State private var duration: TimeInterval = 0
    @State private var fileName: String?
    @State private var showImporter = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    private let service = VoiceStudioService()

    private var hasEnoughAudio: Bool {
        guard audio != nil else { return false }
        return mode == .upload || duration >= VoiceStudioService.cloneMinSeconds
    }

    private var canSubmit: Bool {
        hasEnoughAudio && consent && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !recorder.isRecording && !isBusy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Способ", selection: $mode) {
                        ForEach(Mode.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _ in
                        recorder.cancel()
                        audio = nil
                        duration = 0
                        fileName = nil
                    }

                    if mode == .record {
                        recordCard
                    } else {
                        uploadCard
                    }

                    studioField("Название голоса", text: $name)

                    Button {
                        consent.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: consent ? "checkmark.square.fill" : "square")
                                .font(.system(size: 22))
                                .foregroundStyle(consent ? studioAccent : .white.opacity(0.5))
                            Text("Это мой голос, или у меня есть право его использовать. Запись передаётся сервису синтеза только для создания голоса и у нас не хранится")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(consent ? .isSelected : [])

                    studioError(errorMessage)

                    StudioPrimaryButton(
                        title: "Создать за \(price) кредитов",
                        icon: "mic.fill",
                        enabled: canSubmit,
                        busy: isBusy,
                        action: submit
                    )
                }
                .padding(18)
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea())
            .navigationTitle("Свой голос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(studioAccent)
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .audio],
                allowsMultipleSelection: false
            ) { result in
                pickFile(result)
            }
            .onChange(of: recorder.elapsed) { value in
                // Автостоп на 90 секундах.
                if recorder.isRecording, value >= VoiceStudioService.cloneMaxSeconds {
                    finishRecording()
                }
            }
            .onDisappear {
                recorder.cancel()
                player.stop()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var recordCard: some View {
        let seconds = recorder.isRecording ? recorder.elapsed : duration
        let progress = min(1, seconds / VoiceStudioService.cloneMaxSeconds)
        return VStack(spacing: 12) {
            Text("Читайте любой текст спокойно, в тихой комнате")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Text(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
                .font(.system(size: 38, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(recorder.isRecording ? studioAccent : .white)
            Text("нужно 30–90 секунд")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            ProgressView(value: progress)
                .tint(seconds >= VoiceStudioService.cloneMinSeconds ? studioAccent : .orange)
            HStack(spacing: 14) {
                Button {
                    if recorder.isRecording {
                        finishRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(recorder.isRecording ? .white : studioInk)
                        .frame(width: 66, height: 66)
                        .background(recorder.isRecording ? Color.red : studioAccent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.isRecording ? "Стоп" : "Записать")

                if let audio, !recorder.isRecording {
                    StudioPlayButton(isPlaying: player.playingKey == "take", label: "Прослушать запись") {
                        player.toggle(key: "take", audio: audio.data)
                    }
                    Button {
                        startRecording()
                    } label: {
                        Label("Перезаписать", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if recorder.permissionDenied {
                Text("Нет доступа к микрофону — разрешите его в Настройках или загрузите файл")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if audio != nil, !recorder.isRecording, duration < VoiceStudioService.cloneMinSeconds {
                Text("Мало — запишите хотя бы 30 секунд")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var uploadCard: some View {
        Button {
            showImporter = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(studioAccent)
                Text(fileName ?? "Выберите аудиофайл")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("mp3, m4a или wav · до 10 МБ · 30–90 секунд речи")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(studioAccent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
    }

    private func startRecording() {
        errorMessage = nil
        player.stop()
        audio = nil
        duration = 0
        recorder.cancel()
        Task { await recorder.start() }
    }

    private func finishRecording() {
        guard let take = recorder.stop() else { return }
        audio = (take.data, take.mime, take.ext)
        duration = take.duration
    }

    private func pickFile(_ result: Result<[URL], Error>) {
        errorMessage = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Не удалось открыть файл."
            return
        }
        guard data.count <= VoiceStudioService.cloneMaxBytes else {
            errorMessage = "Файл больше 10 МБ."
            return
        }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "mp3": mime = "audio/mpeg"
        case "m4a", "mp4", "aac": mime = "audio/mp4"
        case "wav": mime = "audio/wav"
        default:
            errorMessage = "Нужен файл mp3, m4a или wav."
            return
        }
        audio = (data, mime, ext == "mp4" || ext == "aac" ? "m4a" : ext)
        fileName = url.lastPathComponent
    }

    private func submit() {
        guard let audio, canSubmit else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            guard let token = await accessToken() else {
                errorMessage = VoiceStudioError.missingAccessToken.localizedDescription
                return
            }
            do {
                let result = try await service.clone(
                    name: name,
                    audio: audio.data,
                    mimeType: audio.mime,
                    fileExtension: audio.ext,
                    consent: consent,
                    accessToken: token
                )
                onCreated(result.voice, result.creditsRemaining)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VoiceStudioError.transport.localizedDescription
            }
        }
    }
}

// MARK: - Голос по описанию

struct VoiceDesignSheet: View {
    let price: Int
    let accessToken: () async -> String?
    let onCredits: (Int) -> Void
    let onSaved: (VoiceStudioMyVoice) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var player = VoicePreviewPlayer()
    @State private var descriptionText = ""
    @State private var previews: [VoiceStudioDesignPreview] = []
    @State private var selectedID: String?
    @State private var name = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    private let service = VoiceStudioService()

    private let hints = [
        "Женщина 25 лет, звонкий весёлый голос, быстрый темп",
        "Мужчина 40 лет, низкий спокойный голос диктора новостей",
        "Пожилой мужчина, тёплый хрипловатый голос рассказчика"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $descriptionText)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .padding(8)
                        if descriptionText.isEmpty {
                            Text("Например: мужчина 35 лет, низкий бархатный голос, спокойный, уверенный")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(14)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if previews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(hints, id: \.self) { hint in
                                Button {
                                    descriptionText = hint
                                } label: {
                                    Text(hint)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .multilineTextAlignment(.leading)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .background(Color.white.opacity(0.055))
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    StudioPrimaryButton(
                        title: (previews.isEmpty ? "3 варианта" : "Ещё 3 варианта") + " · \(price) кредитов",
                        icon: "wand.and.stars",
                        enabled: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20,
                        busy: isBusy && previews.isEmpty,
                        action: generate
                    )

                    if !previews.isEmpty {
                        Text("Варианты")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        ForEach(Array(previews.enumerated()), id: \.element.id) { index, preview in
                            previewRow(index: index, preview: preview)
                        }
                        studioField("Название голоса", text: $name)
                        StudioPrimaryButton(
                            title: "Выбрать этот голос",
                            icon: "checkmark",
                            enabled: selectedID != nil && !isBusy,
                            busy: isBusy && !previews.isEmpty,
                            action: save
                        )
                    }

                    studioError(errorMessage)
                }
                .padding(18)
            }
            .background(Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea())
            .navigationTitle("Голос по описанию")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Закрыл с выбранным вариантом — сохраняем его (бесплатно), иначе
                    // оплаченные превью пропадали и голос не попадал в «Мои голоса» (баг 30.10).
                    Button(hasUnsavedChoice ? "Готово" : "Закрыть") {
                        if hasUnsavedChoice { save() } else { dismiss() }
                    }
                    .foregroundStyle(studioAccent)
                    .disabled(isBusy)
                }
            }
            .onDisappear { player.stop() }
        }
        // Свайп вниз не должен терять оплаченные варианты: закрытие — только кнопкой.
        .interactiveDismissDisabled(hasUnsavedChoice || isBusy)
        .preferredColorScheme(.dark)
    }

    private var hasUnsavedChoice: Bool { selectedID != nil && !previews.isEmpty }

    /// Пустое название — начало описания (лимит сервера 40 символов).
    private var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let text = descriptionText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return text.count <= 40 ? text : String(text.prefix(39)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func previewRow(index: Int, preview: VoiceStudioDesignPreview) -> some View {
        let isSelected = selectedID == preview.id
        return HStack(spacing: 12) {
            StudioPlayButton(isPlaying: player.playingKey == preview.id, label: "Прослушать вариант \(index + 1)") {
                player.toggle(key: preview.id, audio: preview.audio)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Вариант \(index + 1)")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSelected ? studioAccent : .white)
                Text("\(Int(preview.durationSeconds.rounded())) сек")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(studioAccent)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 62)
        .background(isSelected ? studioAccent.opacity(0.10) : Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? studioAccent : Color.white.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = preview.id }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func generate() {
        isBusy = true
        errorMessage = nil
        player.stop()
        Task { @MainActor in
            defer { isBusy = false }
            guard let token = await accessToken() else {
                errorMessage = VoiceStudioError.missingAccessToken.localizedDescription
                return
            }
            do {
                let result = try await service.design(description: descriptionText, accessToken: token)
                previews = result.previews
                selectedID = result.previews.first?.id
                onCredits(result.creditsRemaining)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VoiceStudioError.transport.localizedDescription
            }
        }
    }

    private func save() {
        guard let selectedID, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            guard let token = await accessToken() else {
                errorMessage = VoiceStudioError.missingAccessToken.localizedDescription
                return
            }
            do {
                let voice = try await service.saveDesign(
                    generatedVoiceID: selectedID,
                    name: resolvedName,
                    description: descriptionText,
                    accessToken: token
                )
                onSaved(voice)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? VoiceStudioError.transport.localizedDescription
            }
        }
    }
}
