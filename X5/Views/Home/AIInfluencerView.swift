import AVKit
import PhotosUI
import SwiftUI
import UIKit

private struct CharacterImageCandidate: Identifiable {
    let id = UUID()
    let image: UIImage
    let assetID: String
}

private enum CharacterKind: String, CaseIterable, Identifiable {
    case human, creature, hybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .human: return "Человек"
        case .creature: return "Существо"
        case .hybrid: return "Гибрид"
        }
    }
}

private enum InfluencerLanguage: String, CaseIterable, Identifiable {
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

private enum CharacterImageFormat: String, CaseIterable, Identifiable {
    case square, portrait, landscape
    var id: String { rawValue }
    var title: String {
        switch self {
        case .square: return "1:1"
        case .portrait: return "9:16"
        case .landscape: return "16:9"
        }
    }
}

private enum CharacterImageQuality: String, CaseIterable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var title: String { self == .standard ? "Стандарт · 1K" : "Высокое · 2K" }
}

struct AIInfluencerView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser

    @State private var step = 1
    @State private var capabilities: AIStudioCapabilities?
    @State private var savedCharacters: [AIStudioCharacter] = []
    @State private var character: AIStudioCharacter?
    @State private var name = ""
    @State private var kind = CharacterKind.human
    @State private var gender = "Женщина"
    @State private var age = 25
    @State private var origin = "Казахстан"
    @State private var face = ""
    @State private var bodyDescription = ""
    @State private var skin = ""
    @State private var hair = ""
    @State private var outfit = ""
    @State private var accessories = ""
    @State private var extra = ""
    @State private var imageProvider = ImageGenerationProvider.gptImage2
    @State private var imageFormat = CharacterImageFormat.portrait
    @State private var imageQuality = CharacterImageQuality.standard
    // Галерея через UIKit (X5PhotoPickerPresenter): SwiftUI-шная после Face ID
    // закрывалась и открывалась по кругу (Адильхан 10.10).
    @State private var showingReferencePicker = false
    @State private var referenceImage: UIImage?
    @State private var referenceData: Data?
    @State private var confirmsImageRights = false
    @State private var imageCandidates: [CharacterImageCandidate] = []
    @State private var selectedImageID: UUID?
    @State private var voice = VoiceGenerationVoice.brightHeroine
    @State private var language = InfluencerLanguage.ru
    @State private var voiceStability = VoiceGenerationStability.balanced
    @State private var speed = 1.0
    @State private var testPhrase = "Привет! Я новый виртуальный автор Xfive marketing."
    @State private var voiceResult: VoiceGenerationResult?
    @State private var voicePlayer: AVPlayer?
    @State private var scene = ""
    @State private var speechText = ""
    @State private var aspectRatio = "9:16"
    @State private var durationSeconds = 5
    @State private var finalJob: AIStudioAsyncJob?
    @State private var finalPlayer: AVPlayer?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let studio = AIStudioService()
    private let voiceService = VoiceGenerationService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                header
                stepRail
                switch step {
                case 1: characterForm
                case 2: imageStep
                case 3: voiceStep
                default: finalStep
                }
                if let errorMessage { errorCard(errorMessage) }
            }
            .padding(18)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { X5Background() }
        .navigationTitle("AI-инфлюенсер")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadCapabilities() }
        .x5SinglePhotoPicker(isPresented: $showingReferencePicker) { provider in
            Task { await loadReference(provider) }
        }
        .onChange(of: imageProvider) { provider in
            if provider != .nanoBanana2 { imageQuality = .standard }
        }
        .onDisappear {
            voicePlayer?.pause()
            finalPlayer?.pause()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.rectangle.stack.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                Spacer()
                Text("4 ЭТАПА")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentColor)
            }
            Text("Создайте постоянного персонажа")
                .font(.system(size: 27, weight: .black))
                .foregroundStyle(.white)
            Text("Образ и голос сохраняются в аккаунте. Следующий этап открывается только после подтверждения результата.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(17)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.12)
    }

    private var stepRail: some View {
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { value in
                VStack(spacing: 5) {
                    Circle()
                        .fill(value <= step ? Color.accentColor : Color.white.opacity(0.12))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Text("\(value)")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(value <= step ? Color.black : Color.white.opacity(0.5))
                        }
                    Text(["Персонаж", "Изображение", "Голос", "Видео"][value - 1])
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(value == step ? Color.white : Color.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                if value < 4 {
                    Rectangle()
                        .fill(value < step ? Color.accentColor : Color.white.opacity(0.1))
                        .frame(height: 2)
                        .offset(y: -8)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var characterForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("1 · ПЕРСОНАЖ")
            if !savedCharacters.isEmpty {
                Menu {
                    ForEach(savedCharacters) { saved in
                        Button(saved.name) { resume(saved) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Сохранённые персонажи")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.48))
                            Text(character?.name ?? "Выбрать и продолжить")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.white.opacity(0.38))
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                }
            }
            Picker("Тип", selection: $kind) {
                ForEach(CharacterKind.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            field("Имя персонажа", text: $name)
            HStack(spacing: 10) {
                Menu {
                    ForEach(["Женщина", "Мужчина", "Нейтральный"], id: \.self) { option in
                        Button(option) { gender = option }
                    }
                } label: { menuLabel("Пол", gender) }
                Stepper("Возраст: \(age)", value: $age, in: 18...100)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            field("Происхождение", text: $origin)
            field("Лицо и черты", text: $face, lines: 2)
            field("Телосложение", text: $bodyDescription, lines: 2)
            field("Кожа", text: $skin, lines: 2)
            field("Волосы", text: $hair, lines: 2)
            field("Одежда", text: $outfit, lines: 2)
            field("Аксессуары", text: $accessories, lines: 2)
            field("Дополнительные детали", text: $extra, lines: 3)

            Button { showingReferencePicker = true } label: {
                HStack(spacing: 10) {
                    if let referenceImage {
                        Image(uiImage: referenceImage)
                            .resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "person.crop.square.badge.plus")
                            .font(.system(size: 21)).frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(referenceImage == nil ? "Добавить своё лицо" : "Заменить референс")
                            .font(.subheadline.bold())
                        Text("Необязательно")
                            .font(.caption).foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            if referenceImage != nil {
                Toggle("У меня есть права на это изображение", isOn: $confirmsImageRights)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .tint(Color.accentColor)
            }

            primaryButton(title: isWorking ? "Сохраняем…" : "Сохранить персонажа", enabled: canSaveCharacter) {
                saveCharacter()
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.08)
    }

    private var imageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("2 · ИЗОБРАЖЕНИЕ")
            if capabilities?.tool("image_generation").available == false {
                unavailableCard(capabilities?.tool("image_generation").unavailableReason)
            }

            Picker("Модель", selection: $imageProvider) {
                ForEach(availableImageProviders) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .tint(Color.accentColor)

            HStack(spacing: 10) {
                Picker("Формат", selection: $imageFormat) {
                    ForEach(CharacterImageFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.accentColor)

                Picker("Качество", selection: $imageQuality) {
                    ForEach(CharacterImageQuality.allCases) { quality in
                        Text(quality.title)
                            .tag(quality)
                            .disabled(quality == .high && imageProvider != .nanoBanana2)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.accentColor)
            }

            if imageCandidates.isEmpty {
                Text("Будут созданы два варианта. Выберите один — именно этот образ сохранится для следующих роликов.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.60))
                primaryButton(
                    title: isWorking ? "Создаём варианты…" : "Создать 2 варианта · 120 кредитов",
                    enabled: canGenerateCharacterImage
                ) { generateCharacterImages() }
            } else {
                HStack(spacing: 10) {
                    ForEach(imageCandidates) { candidate in
                        Button {
                            selectedImageID = candidate.id
                        } label: {
                            Image(uiImage: candidate.image)
                                .resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 230)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(selectedImageID == candidate.id ? Color.accentColor : Color.white.opacity(0.12), lineWidth: 3)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                primaryButton(title: isWorking ? "Подтверждаем…" : "Подтвердить образ", enabled: selectedImageID != nil && !isWorking) {
                    approveImage()
                }
                Button("Создать заново") { imageCandidates = []; selectedImageID = nil }
                    .font(.subheadline.bold()).foregroundStyle(Color.accentColor)
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.08)
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("3 · ГОЛОС")
            Picker("Голос MiniMax", selection: $voice) {
                ForEach(VoiceGenerationVoice.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .tint(Color.accentColor)
            Picker("Подача", selection: $voiceStability) {
                ForEach(VoiceGenerationStability.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Picker("Язык", selection: $language) {
                ForEach(InfluencerLanguage.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Скорость").font(.subheadline.bold())
                Slider(value: $speed, in: 0.7...1.2, step: 0.1)
                Text(String(format: "%.1f×", speed)).foregroundStyle(Color.accentColor)
            }
            .foregroundStyle(.white)
            field("Тестовая фраза", text: $testPhrase, lines: 3)

            if let voiceResult {
                Button {
                    if voicePlayer == nil { voicePlayer = AVPlayer(url: voiceResult.audioURL) }
                    voicePlayer?.play()
                } label: {
                    Label("Прослушать тест", systemImage: "play.fill")
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                primaryButton(title: isWorking ? "Подтверждаем…" : "Подтвердить голос", enabled: !isWorking) {
                    approveVoice()
                }
                Button("Создать другой тест") {
                    voicePlayer?.pause(); voicePlayer = nil; self.voiceResult = nil
                }
                .font(.subheadline.bold()).foregroundStyle(Color.accentColor)
            } else {
                primaryButton(
                    title: isWorking ? "Создаём тест…" : "Создать тест · \(VoiceGenerationService.creditCost(for: testPhrase)) кредитов",
                    enabled: !isWorking && !testPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) { generateVoiceTest() }
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.08)
    }

    private var finalStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("4 · ВИДЕО")
            if capabilities?.tool("ai_influencer").available == false {
                unavailableCard(capabilities?.tool("ai_influencer").unavailableReason)
            }
            field("Сцена и движение", text: $scene, lines: 4)
            field("Текст речи", text: $speechText, lines: 5)
            Picker("Формат", selection: $aspectRatio) {
                Text("9:16").tag("9:16")
                Text("16:9").tag("16:9")
            }
            .pickerStyle(.segmented)
            Picker("Длительность", selection: $durationSeconds) {
                Text("5 сек").tag(5)
                Text("10 сек").tag(10)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 7) {
                breakdown("MiniMax · финальная речь", VoiceGenerationService.creditCost(for: speechText))
                breakdown("Seedance · \(durationSeconds) сек", durationSeconds == 5 ? 650 : 1200)
                breakdown("Sync Lipsync · \(durationSeconds) сек", durationSeconds * 50)
                Divider().overlay(Color.white.opacity(0.10))
                breakdown("Итого", finalCost, strong: true)
            }
            .padding(13)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))

            primaryButton(title: isWorking ? "Создаём финальный ролик…" : "Создать за \(finalCost) кредитов", enabled: canGenerateFinal) {
                generateFinal()
            }

            if let finalJob {
                ProgressView(value: finalJob.progress).tint(Color.accentColor)
                Text(finalJob.status == "completed" ? "Ролик готов" : "Этап: \(finalJob.status) · \(Int(finalJob.progress * 100))%")
                    .font(.subheadline.bold()).foregroundStyle(.white.opacity(0.65))
                if let url = finalJob.resultURL {
                    VideoPlayer(player: finalPlayer ?? AVPlayer(url: url))
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .onAppear {
                            if finalPlayer == nil { finalPlayer = AVPlayer(url: url) }
                            finalPlayer?.play()
                        }
                    ShareLink(item: url) {
                        Label("Отправить MP4", systemImage: "square.and.arrow.up")
                            .font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.08)
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value).font(.system(size: 10, weight: .black)).tracking(1.2).foregroundStyle(.white.opacity(0.46))
    }

    private func field(_ title: String, text: Binding<String>, lines: Int = 1) -> some View {
        TextField(title, text: text, axis: lines > 1 ? .vertical : .horizontal)
            .lineLimit(lines...max(lines, lines + 2))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }

    private func menuLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.46))
            Text(value).font(.subheadline.bold()).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func primaryButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if isWorking { ProgressView().tint(.black) }
                Text(title).font(.headline)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(enabled ? Color.accentColor : Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func unavailableCard(_ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Сервис временно недоступен", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(unavailableReason(reason))
                .font(.caption).foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.bold()).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
    }

    private func breakdown(_ title: String, _ value: Int, strong: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(strong ? 1 : 0.62))
            Spacer()
            Text("\(value)").foregroundStyle(strong ? Color.accentColor : Color.white)
        }
        .font(.system(size: 13, weight: strong ? .black : .semibold))
    }

    private var canSaveCharacter: Bool {
        !isWorking && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (referenceImage == nil || confirmsImageRights)
    }

    private var imageProviderAvailable: Bool {
        capabilities?.tool("image_generation").available == true
    }

    private var availableImageProviders: [ImageGenerationProvider] {
        guard let capabilities else { return ImageGenerationProvider.allCases }
        return ImageGenerationProvider.allCases.filter {
            capabilities.supportsImageModel($0.rawValue)
        }
    }

    private var canGenerateCharacterImage: Bool {
        !isWorking && imageProviderAvailable && character != nil
    }

    private var canGenerateFinal: Bool {
        !isWorking && capabilities?.tool("ai_influencer").available == true &&
        character?.status == "voice_approved" &&
        scene.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 &&
        !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var finalCost: Int {
        VoiceGenerationService.creditCost(for: speechText) +
        (durationSeconds == 5 ? 650 : 1200) + durationSeconds * 50
    }

    private func unavailableReason(_ reason: String?) -> String {
        switch reason {
        case "provider_balance_or_quota":
            return "У провайдера закончился баланс или квота. Запуск и списание кредитов заблокированы."
        case "lipsync_not_configured", "provider_not_configured":
            return "Sync Lipsync ещё не подключён. Запуск и списание кредитов заблокированы."
        default:
            return "Последняя проверка провайдера не пройдена. Кредиты не списываются."
        }
    }

    private func loadCapabilities() async {
        guard let token = await auth.freshAccessToken() else { return }
        do {
            async let loadedCapabilities = studio.capabilities(accessToken: token)
            async let loadedCharacters = studio.characters(accessToken: token)
            capabilities = try await loadedCapabilities
            savedCharacters = try await loadedCharacters
            if let first = availableImageProviders.first,
               !availableImageProviders.contains(imageProvider) {
                imageProvider = first
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func resume(_ saved: AIStudioCharacter) {
        character = saved
        name = saved.name
        kind = CharacterKind(rawValue: saved.characterKind) ?? .human
        gender = saved.gender ?? "Нейтральный"
        age = saved.age ?? 25
        origin = saved.origin ?? ""
        face = saved.faceDescription ?? ""
        bodyDescription = saved.bodyDescription ?? ""
        skin = saved.skinDescription ?? ""
        hair = saved.hairDescription ?? ""
        outfit = saved.outfitDescription ?? ""
        accessories = saved.accessoriesDescription ?? ""
        extra = saved.extraDescription ?? ""
        imageProvider = ImageGenerationProvider(rawValue: saved.imageModel) ?? .gptImage2
        if let voiceID = saved.voiceID, let savedVoice = VoiceGenerationVoice(rawValue: voiceID) {
            voice = savedVoice
        }
        language = InfluencerLanguage(rawValue: saved.voiceLanguage ?? "ru") ?? .ru
        speed = saved.voiceSpeed ?? 1
        imageCandidates = []
        selectedImageID = nil
        voiceResult = nil
        finalJob = nil
        switch saved.status {
        case "voice_approved", "ready": step = 4
        case "image_approved": step = 3
        default: step = 2
        }
        X5Feedback.selection()
    }

    private func loadReference(_ provider: NSItemProvider) async {
        guard let data = try? await PickedPhotoLoader.loadData(from: provider),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.84),
              jpeg.count <= ImageGenerationReferencePolicy.maximumDecodedBytesPerImage
        else {
            referenceImage = nil
            referenceData = nil
            confirmsImageRights = false
            return
        }
        referenceImage = image
        referenceData = jpeg
        confirmsImageRights = false
    }

    private func saveCharacter() {
        guard canSaveCharacter else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await auth.freshAccessToken() else {
                errorMessage = AIStudioServiceError.notAuthenticated.localizedDescription
                return
            }
            do {
                let created = try await studio.createCharacter(fields: [
                    "name": name,
                    "character_kind": kind.rawValue,
                    "gender": gender,
                    "age": age,
                    "origin": origin,
                    "face_description": face,
                    "body_description": bodyDescription,
                    "skin_description": skin,
                    "hair_description": hair,
                    "outfit_description": outfit,
                    "accessories_description": accessories,
                    "extra_description": extra,
                    "image_model": imageProvider.rawValue
                ], accessToken: token)
                character = created
                savedCharacters.removeAll { $0.id == created.id }
                savedCharacters.insert(created, at: 0)
                step = 2
                X5Feedback.success()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func generateCharacterImages() {
        guard canGenerateCharacterImage else { return }
        guard let profileOperation = currentUser.operationContext() else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await currentUser.accessTokenForOperation(profileOperation, refresh: {
                await auth.freshAccessToken(minimumValidity: 5 * 60)
            }) else { return }
            do {
                var references: [ImageGenerationReference] = []
                if let referenceData, confirmsImageRights {
                    references.append(ImageGenerationReference(
                        mimeType: "image/jpeg",
                        base64: referenceData.base64EncodedString(),
                        role: .heroFace
                    ))
                }
                let category = ImageGenerationCatalog.categories.first { $0.id == "ai_character" }
                    ?? ImageGenerationCatalog.custom
                let response = try await auth.supabase.generateImageWithAccessToken(
                    prompt: characterPrompt,
                    provider: imageProvider,
                    category: category,
                    quantity: 2,
                    size: characterImageSize,
                    referenceImages: references,
                    idempotencyKey: UUID().uuidString.lowercased(),
                    accessToken: token
                )
                guard currentUser.isCurrent(profileOperation) else { return }
                let encoded = response.imageBase64s ?? [response.imageBase64]
                let ids = response.assetIds ?? []
                imageCandidates = encoded.enumerated().compactMap { index, value in
                    guard ids.indices.contains(index),
                          let data = Data(base64Encoded: value),
                          let image = UIImage(data: data)
                    else { return nil }
                    return CharacterImageCandidate(image: image, assetID: ids[index])
                }
                guard !imageCandidates.isEmpty else { throw AIStudioServiceError.invalidResponse }
                selectedImageID = imageCandidates.first?.id
                if let remaining = response.creditsRemaining { currentUser.applyCreditsRemaining(remaining, for: profileOperation) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var characterPrompt: String {
        """
        Создай оригинального синтетического персонажа X5. Не используй лицо известного или реального человека без приложенного разрешённого референса.
        Тип: \(kind.title). Имя: \(name). Пол: \(gender). Возраст: \(age). Происхождение: \(origin).
        Лицо: \(face). Телосложение: \(bodyDescription). Кожа: \(skin). Волосы: \(hair).
        Одежда: \(outfit). Аксессуары: \(accessories). Дополнительно: \(extra).
        Реалистичный портрет по пояс, естественная анатомия, чистый нейтральный фон, без текста, водяных знаков и чужих логотипов.
        """
    }

    private var characterImageSize: ImageGenerationSize {
        switch (imageFormat, imageQuality) {
        case (.square, .standard): return .square
        case (.portrait, .standard): return .portrait
        case (.landscape, .standard): return .landscape
        case (.square, .high): return .square2K
        case (.portrait, .high): return .portrait2K
        case (.landscape, .high): return .landscape2K
        }
    }

    private func approveImage() {
        guard let character, let selectedImageID,
              let candidate = imageCandidates.first(where: { $0.id == selectedImageID })
        else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await auth.freshAccessToken() else { return }
            do {
                let updated = try await studio.approveCharacterImage(
                    characterID: character.id,
                    assetID: candidate.assetID,
                    accessToken: token
                )
                self.character = updated
                replaceSavedCharacter(updated)
                step = 3
                X5Feedback.success()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func generateVoiceTest() {
        guard !testPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let profileOperation = currentUser.operationContext() else { return }
        isWorking = true
        errorMessage = nil
        voicePlayer?.pause()
        voicePlayer = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await currentUser.accessTokenForOperation(profileOperation, refresh: {
                await auth.freshAccessToken(minimumValidity: 5 * 60)
            }) else { return }
            do {
                let result = try await voiceService.generate(
                    text: testPhrase,
                    voice: voice,
                    stability: voiceStability,
                    speed: speed,
                    languageCode: language.rawValue,
                    requestID: UUID().uuidString.lowercased(),
                    accessToken: token
                )
                guard currentUser.isCurrent(profileOperation) else { return }
                guard result.assetID != nil else { throw AIStudioServiceError.invalidResponse }
                voiceResult = result
                voicePlayer = AVPlayer(url: result.audioURL)
                currentUser.applyCreditsRemaining(result.creditsRemaining, for: profileOperation)
                X5Feedback.success()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func approveVoice() {
        guard let character, let result = voiceResult, let assetID = result.assetID else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await auth.freshAccessToken() else { return }
            do {
                let updated = try await studio.approveCharacterVoice(
                    characterID: character.id,
                    assetID: assetID,
                    voice: voice,
                    language: language.rawValue,
                    speed: speed,
                    accessToken: token
                )
                self.character = updated
                replaceSavedCharacter(updated)
                step = 4
                X5Feedback.success()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func generateFinal() {
        guard canGenerateFinal, let character else { return }
        isWorking = true
        errorMessage = nil
        finalJob = nil
        finalPlayer?.pause()
        finalPlayer = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let token = await auth.freshAccessToken(minimumValidity: 15 * 60) else { return }
            do {
                var current = try await studio.startInfluencer(
                    characterID: character.id,
                    scene: scene,
                    speechText: speechText,
                    aspectRatio: aspectRatio,
                    durationSeconds: durationSeconds,
                    requestID: UUID().uuidString.lowercased(),
                    accessToken: token
                )
                finalJob = current
                for _ in 0..<180 {
                    if current.isTerminal { break }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    current = try await studio.influencerJob(id: current.id, accessToken: token)
                    finalJob = current
                }
                if current.status == "completed", let url = current.resultURL {
                    finalPlayer = AVPlayer(url: url)
                    X5Feedback.success()
                } else if current.isTerminal {
                    throw AIStudioServiceError.server(status: 503, code: current.errorCode, message: nil, retryable: true)
                }
            } catch is CancellationError {
                return
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func replaceSavedCharacter(_ updated: AIStudioCharacter) {
        savedCharacters.removeAll { $0.id == updated.id }
        savedCharacters.insert(updated, at: 0)
    }
}
