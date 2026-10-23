import SwiftUI
import UIKit

enum LiveFruitsFrameLedger {
    typealias Reconciled = (
        frames: [String: String],
        fingerprints: [String: String]
    )

    static func visualFingerprint(for scene: FruitStoryScene) -> String {
        [
            scene.visualPrompt,
            scene.action,
            scene.camera,
        ]
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
        }
        .joined(separator: "\u{1F}")
    }

    static func reconciled(
        scenes: [FruitStoryScene],
        frames: [String: String],
        fingerprints: [String: String]
    ) -> Reconciled {
        var reconciledFrames: [String: String] = [:]
        var reconciledFingerprints: [String: String] = [:]
        for scene in scenes {
            let currentFingerprint = visualFingerprint(for: scene)
            guard
                fingerprints[scene.id] == currentFingerprint,
                let frame = frames[scene.id]
            else {
                continue
            }
            reconciledFrames[scene.id] = frame
            reconciledFingerprints[scene.id] = currentFingerprint
        }
        return (reconciledFrames, reconciledFingerprints)
    }
}

struct LiveFruitsView: View {
    @EnvironmentObject private var auth: Auth

    @State private var fruit = ""
    @State private var personality = ""
    @State private var goal = ""
    @State private var location = ""
    @State private var event = ""
    @State private var ending = ""

    @State private var story: FruitStory?
    @State private var scenes: [FruitStoryScene] = []
    @State private var characterReferenceBase64: String?
    @State private var frameBase64BySceneID: [String: String] = [:]
    @State private var frameFingerprintBySceneID: [String: String] = [:]
    @State private var videoJob: VideoGenerationJob?
    @State private var isCreatingStory = false
    @State private var isCreatingFrames = false
    @State private var regeneratingSceneID: String?
    @State private var isSubmittingVideo = false
    @State private var errorMessage: String?
    @State private var storyTask: Task<Void, Never>?
    @State private var frameGenerationTask: Task<Void, Never>?
    @State private var frameRegenerationTask: Task<Void, Never>?
    @State private var videoSubmissionTask: Task<Void, Never>?
    @State private var videoPollTask: Task<Void, Never>?
    @State private var videoRestoreTask: Task<Void, Never>?
    @State private var lifecycleID = UUID()
    @State private var storyGenerationID = UUID()
    @State private var frameGenerationID = UUID()
    @State private var frameRegenerationID = UUID()
    @State private var videoSubmissionID = UUID()
    @State private var videoPollID = UUID()
    @State private var videoRestoreID = UUID()
    @State private var activeUserID: String?
    @State private var isViewActive = false

    private let storyService = FruitStoryService()
    private let storyPendingStore = FruitStoryPendingRequestStore()
    private let imagePendingStore = LiveFruitsImagePendingRequestStore()
    private let videoService = VideoGenerationService()
    private let localStore = VideoGenerationLocalStore(
        keyPrefix: "x5.live-fruits-video.v1"
    )

    var body: some View {
        NavigationStack {
            List {
                brandHeader
                    .listRowBackground(Color.clear)

                questionnaireSection

                if let story {
                    storySummary(story)
                    storyboardSection
                    visualProductionSection(story)
                    videoSection(story)
                } else if videoJob != nil {
                    restoredVideoSection
                }

                if let errorMessage {
                    errorCard(errorMessage)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { X5Background() }
            .navigationTitle("Живые фрукты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onChange(of: scenes) { _ in
                reconcileFramesAfterSceneMutation()
                invalidateVideoState()
            }
            .onChange(of: auth.userId) { userID in
                beginAccountLifecycle(for: userID)
            }
            .onAppear {
                beginAccountLifecycle(for: auth.userId)
            }
            .onDisappear {
                isViewActive = false
                lifecycleID = UUID()
                cancelAllOperations()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Xfive marketing")
                .font(.system(size: 12, weight: .black))
                .tracking(1.4)
                .foregroundColor(X5Style.blue)
            Text("Один фрукт. Три сцены. Один ролик.")
                .font(.system(size: 27, weight: .black))
                .foregroundColor(.white)
            Text("Заполните анкету, отредактируйте раскадровку и соберите вертикальную историю 9:16.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
        }
        .padding(18)
        .x5ClearGlass(cornerRadius: 24, highlight: 0.10)
        .padding(.vertical, 8)
    }

    private var questionnaireSection: some View {
        Section {
            questionnaireField("Фрукт", text: $fruit, prompt: "Например, манго")
            questionnaireField("Характер", text: $personality, prompt: "Смелый, добрый")
            questionnaireField("Цель", text: $goal, prompt: "Что должен сделать герой")
            questionnaireField("Локация", text: $location, prompt: "Где происходит история")
            questionnaireField("Событие", text: $event, prompt: "Главное действие")
            questionnaireField("Финал", text: $ending, prompt: "Чем всё закончится")

            HStack {
                Label("Формат", systemImage: "rectangle.portrait")
                Spacer()
                Text("9:16 · 3 сцены")
                    .foregroundColor(X5Style.blue)
            }
            .font(.system(size: 14, weight: .bold))

            Button {
                createStory()
            } label: {
                actionLabel(
                    isBusy: isCreatingStory,
                    title: "Создать раскадровку",
                    systemImage: "text.badge.star",
                    cost: "Бесплатно"
                )
            }
            .buttonStyle(.plain)
            .disabled(!canCreateStory)
        } header: {
            Text("Анкета персонажа")
        } footer: {
            Text("Укажите ровно один фрукт. Других персонажей-фруктов в истории не будет.")
        }
        .listRowBackground(Color.white.opacity(0.055))
    }

    private func questionnaireField(
        _ title: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.58))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(1...3)
                .foregroundColor(.white)
        }
        .padding(.vertical, 3)
    }

    private func storySummary(_ story: FruitStory) -> some View {
        Section("История") {
            VStack(alignment: .leading, spacing: 8) {
                Text(story.title)
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(.white)
                Text(story.summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                Label(story.characterBible, systemImage: "person.crop.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(X5Style.blueSoft)
            }
            .padding(.vertical, 5)
        }
        .listRowBackground(Color.white.opacity(0.055))
    }

    private var storyboardSection: some View {
        Section {
            ForEach($scenes) { $scene in
                sceneEditor(scene: $scene)
            }
            .onMove(perform: moveScenes)
        } header: {
            HStack {
                Text("Раскадровка")
                Spacer()
                EditButton()
                    .textCase(nil)
                    .disabled(isFrameGenerationBusy || isSubmittingVideo)
            }
        } footer: {
            Text("Все поля можно исправить. Нажмите «Изменить», чтобы перетаскивать сцены.")
        }
        .listRowBackground(Color.white.opacity(0.055))
    }

    private func sceneEditor(scene: Binding<FruitStoryScene>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Название сцены", text: scene.title)
                .font(.system(size: 17, weight: .black))
                .foregroundColor(.white)
            editableField("Кадр", text: scene.visualPrompt)
            editableField("Действие", text: scene.action)
            editableField("Камера", text: scene.camera)
            editableField("Надпись", text: scene.caption)

            if let encoded = frameBase64BySceneID[scene.wrappedValue.id],
               let image = decodedImage(encoded) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if characterReferenceBase64 != nil {
                Button {
                    regenerateFrame(for: scene.wrappedValue)
                } label: {
                    HStack(spacing: 8) {
                        if regeneratingSceneID == scene.wrappedValue.id {
                            ProgressView()
                                .tint(X5Style.blue)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(
                            regeneratingSceneID == scene.wrappedValue.id
                                ? "Кадр пересоздаётся"
                                : "Пересоздать кадр"
                        )
                        Spacer()
                        // Адильхан 18.10: цена у каждой кнопки, которая тратит кредиты
                        Text(Self.creditsLabel(ImageGenerationCatalog.creditCost))
                            .foregroundColor(X5Style.blue.opacity(0.8))
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(X5Style.blue)
                }
                .buttonStyle(.plain)
                .disabled(isFrameGenerationBusy || isSubmittingVideo)
            }
        }
        .padding(.vertical, 7)
        .disabled(isFrameGenerationBusy || isSubmittingVideo)
    }

    private func editableField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.46))
            TextField(title, text: text, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.88))
        }
    }

    private func visualProductionSection(_ story: FruitStory) -> some View {
        Section("Персонаж и кадры") {
            if let encoded = characterReferenceBase64,
               let image = decodedImage(encoded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Референс персонажа")
                        .font(.system(size: 14, weight: .bold))
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Button {
                createCharacterAndFrames(story)
            } label: {
                actionLabel(
                    isBusy: isCreatingFrames,
                    title: "Создать референс и 3 кадра",
                    systemImage: "photo.stack",
                    cost: Self.creditsLabel(framesCreditCost)
                )
            }
            .buttonStyle(.plain)
            .disabled(
                isCreatingStory
                    || isFrameGenerationBusy
                    || isSubmittingVideo
                    || scenes.count != 3
            )
        }
        .listRowBackground(Color.white.opacity(0.055))
    }

    private func videoSection(_ story: FruitStory) -> some View {
        Section("Финальный ролик") {
            HStack {
                Label("9:16", systemImage: "rectangle.portrait")
                Spacer()
                Label("10 сек.", systemImage: "clock")
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white.opacity(0.72))

            Button {
                submitVideo(story)
            } label: {
                actionLabel(
                    isBusy: isSubmittingVideo,
                    title: "Запустить видео",
                    systemImage: "video.badge.waveform",
                    cost: Self.creditsLabel(Self.videoCreditCost)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitVideo)

            if let videoJob {
                videoJobStatusView(videoJob)
            }
        }
        .listRowBackground(Color.white.opacity(0.055))
    }

    private var restoredVideoSection: some View {
        Section("Последний ролик") {
            if let videoJob {
                videoJobStatusView(videoJob)
            }
        }
        .listRowBackground(Color.white.opacity(0.055))
    }

    private func videoJobStatusView(
        _ job: VideoGenerationJob
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(videoStatusTitle(job.status))
                .font(.system(size: 16, weight: .black))
            ProgressView(value: min(max(job.progress, 0), 1))
                .tint(X5Style.blue)
            if job.status == .completed,
               let resultURL = job.resultURL {
                Link(destination: resultURL) {
                    Label(
                        "Открыть готовое видео",
                        systemImage: "play.circle.fill"
                    )
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(X5Style.blue)
                }
            }
        }
    }

    private func actionLabel(
        isBusy: Bool,
        title: String,
        systemImage: String,
        cost: String? = nil
    ) -> some View {
        HStack {
            if isBusy {
                ProgressView()
                    .tint(.black)
            } else {
                Image(systemName: systemImage)
            }
            // Адильхан 18.10: «везде информация нужна по стоимости» — цена второй строкой под названием
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let cost {
                    Text(cost)
                        .font(.system(size: 12, weight: .bold))
                        .opacity(0.72)
                }
            }
            Spacer()
        }
        .foregroundColor(.black)
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(X5Style.blue)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var questionnaire: FruitStoryQuestionnaire {
        FruitStoryQuestionnaire(
            fruit: fruit,
            personality: personality,
            goal: goal,
            location: location,
            event: event,
            ending: ending,
            aspectRatio: "9:16"
        )
    }

    private var canCreateStory: Bool {
        let fields = [fruit, personality, goal, location, event, ending]
        return fields.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
            && !isCreatingStory
            && !isFrameGenerationBusy
            && !isSubmittingVideo
    }

    private var canSubmitVideo: Bool {
        scenes.count == 3
            && scenes.allSatisfy { frameBase64BySceneID[$0.id] != nil }
            && !isFrameGenerationBusy
            && !isSubmittingVideo
    }

    // Цена на «Создать референс и 3 кадра» = столько картинок, сколько реально уйдёт в генерацию
    // (та же логика, что в createCharacterAndFrames): полный готовый набор пересоздаётся целиком,
    // иначе — персонаж (если его ещё нет) и недостающие кадры.
    private var framesCreditCost: Int {
        let reconciled = LiveFruitsFrameLedger.reconciled(
            scenes: scenes,
            frames: frameBase64BySceneID,
            fingerprints: frameFingerprintBySceneID
        )
        let missingFrames = scenes.filter { reconciled.frames[$0.id] == nil }.count
        let images: Int
        if characterReferenceBase64 != nil && missingFrames == 0 {
            images = scenes.count + 1
        } else {
            images = missingFrames + (characterReferenceBase64 == nil ? 1 : 0)
        }
        return ImageGenerationCatalog.creditCost * max(1, images)
    }

    // 10 сек — как VIDEO_CREDIT_COSTS[10] в supabase/functions/generate-video/contract.mjs
    private static let videoCreditCost = 1_200

    private static func creditsLabel(_ credits: Int) -> String {
        "\(credits) кредитов"
    }

    private var isFrameGenerationBusy: Bool {
        isCreatingFrames || regeneratingSceneID != nil
    }

    private enum ImageOperation {
        case frameGeneration
        case frameRegeneration
    }

    private func beginAccountLifecycle(for userID: String?) {
        let normalizedUserID = userID.flatMap {
            UUID(uuidString: $0)?.uuidString.lowercased()
        }
        let accountChanged = activeUserID != normalizedUserID

        cancelAllOperations()
        lifecycleID = UUID()
        isViewActive = true
        activeUserID = normalizedUserID
        if accountChanged {
            resetAccountState()
        }
        guard let normalizedUserID else { return }

        let sessionID = lifecycleID
        let generationID = UUID()
        videoRestoreID = generationID
        videoRestoreTask = Task { @MainActor in
            await restoreRecentVideoJobs(
                userID: normalizedUserID,
                lifecycleID: sessionID,
                generationID: generationID
            )
        }
    }

    private func resetAccountState() {
        fruit = ""
        personality = ""
        goal = ""
        location = ""
        event = ""
        ending = ""
        story = nil
        scenes = []
        characterReferenceBase64 = nil
        frameBase64BySceneID = [:]
        frameFingerprintBySceneID = [:]
        videoJob = nil
        errorMessage = nil
        isCreatingStory = false
        isCreatingFrames = false
        regeneratingSceneID = nil
        isSubmittingVideo = false
    }

    private func cancelAllOperations() {
        storyTask?.cancel()
        storyTask = nil
        storyGenerationID = UUID()
        frameGenerationTask?.cancel()
        frameGenerationTask = nil
        frameGenerationID = UUID()
        frameRegenerationTask?.cancel()
        frameRegenerationTask = nil
        frameRegenerationID = UUID()
        videoSubmissionTask?.cancel()
        videoSubmissionTask = nil
        videoSubmissionID = UUID()
        videoPollTask?.cancel()
        videoPollTask = nil
        videoPollID = UUID()
        videoRestoreTask?.cancel()
        videoRestoreTask = nil
        videoRestoreID = UUID()
        isCreatingStory = false
        isCreatingFrames = false
        regeneratingSceneID = nil
        isSubmittingVideo = false
    }

    private func isLifecycleCurrent(_ sessionID: UUID, userID: String) -> Bool {
        isViewActive
            && lifecycleID == sessionID
            && activeUserID == userID
            && auth.userId?.lowercased() == userID
    }

    private func isOperationCurrent(
        _ generationID: UUID,
        currentID: UUID,
        lifecycleID sessionID: UUID,
        userID: String
    ) -> Bool {
        isLifecycleCurrent(sessionID, userID: userID)
            && generationID == currentID
    }

    private func isImageOperationCurrent(
        _ operation: ImageOperation,
        generationID: UUID,
        lifecycleID sessionID: UUID,
        userID: String
    ) -> Bool {
        switch operation {
        case .frameGeneration:
            return isOperationCurrent(
                generationID,
                currentID: frameGenerationID,
                lifecycleID: sessionID,
                userID: userID
            )
        case .frameRegeneration:
            return isOperationCurrent(
                generationID,
                currentID: frameRegenerationID,
                lifecycleID: sessionID,
                userID: userID
            )
        }
    }

    private func reconcileFramesAfterSceneMutation() {
        let reconciled = LiveFruitsFrameLedger.reconciled(
            scenes: scenes,
            frames: frameBase64BySceneID,
            fingerprints: frameFingerprintBySceneID
        )
        frameBase64BySceneID = reconciled.frames
        frameFingerprintBySceneID = reconciled.fingerprints
    }

    private func invalidateVideoState() {
        videoSubmissionTask?.cancel()
        videoSubmissionTask = nil
        videoSubmissionID = UUID()
        videoPollTask?.cancel()
        videoPollTask = nil
        videoPollID = UUID()
        videoJob = nil
        isSubmittingVideo = false
    }

    private func createStory() {
        guard
            canCreateStory,
            let userID = activeUserID,
            UUID(uuidString: userID) != nil,
            isViewActive
        else {
            errorMessage = FruitStoryServiceError.missingAccessToken.localizedDescription
            return
        }

        storyTask?.cancel()
        let sessionID = lifecycleID
        let generationID = UUID()
        storyGenerationID = generationID
        let requestedQuestionnaire = questionnaire
        let storyFingerprint = FruitStoryQuestionnaireFingerprint.make(
            requestedQuestionnaire
        )
        let requestID = storyPendingStore.requestID(
            userID: userID,
            fingerprint: storyFingerprint
        )
        errorMessage = nil
        isCreatingStory = true

        storyTask = Task { @MainActor in
            defer {
                if isOperationCurrent(
                    generationID,
                    currentID: storyGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) {
                    storyTask = nil
                    isCreatingStory = false
                }
            }

            guard let token = await auth.freshAccessToken() else {
                guard isOperationCurrent(
                    generationID,
                    currentID: storyGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = FruitStoryServiceError.missingAccessToken.localizedDescription
                return
            }
            guard isOperationCurrent(
                generationID,
                currentID: storyGenerationID,
                lifecycleID: sessionID,
                userID: userID
            ) else { return }

            do {
                let envelope = try await storyService.generate(
                    questionnaire: requestedQuestionnaire,
                    requestID: requestID,
                    accessToken: token
                )
                try Task.checkCancellation()
                guard isOperationCurrent(
                    generationID,
                    currentID: storyGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }

                story = envelope.story
                scenes = envelope.story.scenes
                characterReferenceBase64 = nil
                frameBase64BySceneID = [:]
                frameFingerprintBySceneID = [:]
                invalidateVideoState()
                storyPendingStore.clear(
                    userID: userID,
                    requestID: requestID
                )
            } catch is CancellationError {
                return
            } catch let error as FruitStoryServiceError {
                guard isOperationCurrent(
                    generationID,
                    currentID: storyGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = error.localizedDescription
            } catch {
                guard isOperationCurrent(
                    generationID,
                    currentID: storyGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = FruitStoryServiceError.serverUnavailable.localizedDescription
            }
        }
    }

    private func moveScenes(from source: IndexSet, to destination: Int) {
        guard !isFrameGenerationBusy, !isSubmittingVideo else { return }
        scenes.move(fromOffsets: source, toOffset: destination)
    }

    private func createCharacterAndFrames(_ story: FruitStory) {
        guard
            scenes.count == 3,
            !isCreatingFrames,
            regeneratingSceneID == nil,
            let userID = activeUserID,
            UUID(uuidString: userID) != nil,
            isViewActive
        else { return }

        frameGenerationTask?.cancel()
        let sessionID = lifecycleID
        let generationID = UUID()
        frameGenerationID = generationID
        let requestedStory = story
        let requestedScenes = scenes
        let reconciled = LiveFruitsFrameLedger.reconciled(
            scenes: requestedScenes,
            frames: frameBase64BySceneID,
            fingerprints: frameFingerprintBySceneID
        )
        let hasCompleteVisualSet = characterReferenceBase64 != nil
            && requestedScenes.allSatisfy {
                reconciled.frames[$0.id] != nil
            }

        if hasCompleteVisualSet {
            characterReferenceBase64 = nil
            frameBase64BySceneID = [:]
            frameFingerprintBySceneID = [:]
        } else {
            frameBase64BySceneID = reconciled.frames
            frameFingerprintBySceneID = reconciled.fingerprints
        }
        let reusableCharacterReference = characterReferenceBase64
        errorMessage = nil
        isCreatingFrames = true
        invalidateVideoState()

        frameGenerationTask = Task { @MainActor in
            defer {
                if isOperationCurrent(
                    generationID,
                    currentID: frameGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) {
                    frameGenerationTask = nil
                    isCreatingFrames = false
                }
            }

            guard let imageAccessToken = await auth.freshAccessToken() else {
                guard isOperationCurrent(
                    generationID,
                    currentID: frameGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = FruitStoryServiceError.missingAccessToken.localizedDescription
                return
            }
            guard isOperationCurrent(
                generationID,
                currentID: frameGenerationID,
                lifecycleID: sessionID,
                userID: userID
            ) else { return }

            do {
                let characterBase64: String
                if let reusableCharacterReference {
                    characterBase64 = reusableCharacterReference
                } else {
                    let characterPrompt = """
                    Character reference sheet for one fruit hero only, full body, front view,
                    clean neutral background, vertical 9:16. \(requestedStory.characterBible)
                    Keep this exact identity for three following storyboard frames.
                    """
                    let characterFingerprint =
                        LiveFruitsImageRequestFingerprint.make(
                            prompt: characterPrompt,
                            provider: .gptImage2,
                            category: ImageGenerationCatalog.custom,
                            quantity: 1,
                            size: .portrait,
                            referenceImages: []
                        )
                    let characterRequestID = imagePendingStore.requestID(
                        userID: userID,
                        slot: "character",
                        fingerprint: characterFingerprint
                    )
                    let character = try await generateImageWithSafeRetry(
                        prompt: characterPrompt,
                        referenceImages: [],
                        idempotencyKey: characterRequestID,
                        accessToken: imageAccessToken,
                        operation: .frameGeneration,
                        generationID: generationID,
                        lifecycleID: sessionID,
                        userID: userID
                    )
                    let validatedCharacter = try validatedImageBase64(character)
                    try Task.checkCancellation()
                    guard isOperationCurrent(
                        generationID,
                        currentID: frameGenerationID,
                        lifecycleID: sessionID,
                        userID: userID
                    ) else { return }
                    characterReferenceBase64 = validatedCharacter
                    imagePendingStore.clear(
                        userID: userID,
                        slot: "character",
                        fingerprint: characterFingerprint,
                        requestID: characterRequestID
                    )
                    characterBase64 = validatedCharacter
                }

                let referenceImages = [
                    ImageGenerationReference(
                        mimeType: "image/png",
                        base64: characterBase64
                    ),
                ]
                for (index, scene) in requestedScenes.enumerated() {
                    try Task.checkCancellation()
                    guard isOperationCurrent(
                        generationID,
                        currentID: frameGenerationID,
                        lifecycleID: sessionID,
                        userID: userID
                    ) else { return }

                    let visualFingerprint =
                        LiveFruitsFrameLedger.visualFingerprint(for: scene)
                    if frameBase64BySceneID[scene.id] != nil,
                       frameFingerprintBySceneID[scene.id] == visualFingerprint {
                        continue
                    }
                    let framePrompt = """
                    Storyboard frame \(index + 1) of 3, vertical 9:16.
                    Use exactly the same single fruit character from the reference.
                    \(scene.visualPrompt). Action: \(scene.action).
                    Camera: \(scene.camera). No other fruit characters.
                    """
                    let frameFingerprint =
                        LiveFruitsImageRequestFingerprint.make(
                            prompt: framePrompt,
                            provider: .gptImage2,
                            category: ImageGenerationCatalog.custom,
                            quantity: 1,
                            size: .portrait,
                            referenceImages: referenceImages
                        )
                    let frameRequestID = imagePendingStore.requestID(
                        userID: userID,
                        slot: "frame.\(scene.id)",
                        fingerprint: frameFingerprint
                    )
                    let response = try await generateImageWithSafeRetry(
                        prompt: framePrompt,
                        referenceImages: referenceImages,
                        idempotencyKey: frameRequestID,
                        accessToken: imageAccessToken,
                        operation: .frameGeneration,
                        generationID: generationID,
                        lifecycleID: sessionID,
                        userID: userID
                    )
                    let validatedFrame = try validatedImageBase64(response)
                    try Task.checkCancellation()
                    guard isOperationCurrent(
                        generationID,
                        currentID: frameGenerationID,
                        lifecycleID: sessionID,
                        userID: userID
                    ) else { return }

                    frameBase64BySceneID[scene.id] = validatedFrame
                    frameFingerprintBySceneID[scene.id] = visualFingerprint
                    imagePendingStore.clear(
                        userID: userID,
                        slot: "frame.\(scene.id)",
                        fingerprint: frameFingerprint,
                        requestID: frameRequestID
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard isOperationCurrent(
                    generationID,
                    currentID: frameGenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = "Не удалось создать референс и три кадра. Кредиты за успешные изображения могли быть списаны."
            }
        }
    }

    private func regenerateFrame(for scene: FruitStoryScene) {
        guard
            !isCreatingFrames,
            regeneratingSceneID == nil,
            let sceneIndex = scenes.firstIndex(where: { $0.id == scene.id }),
            let characterReference = characterReferenceBase64,
            let userID = activeUserID,
            UUID(uuidString: userID) != nil,
            isViewActive
        else { return }

        frameRegenerationTask?.cancel()
        let sessionID = lifecycleID
        let generationID = UUID()
        frameRegenerationID = generationID
        let requestedScene = scene
        errorMessage = nil
        regeneratingSceneID = scene.id

        frameRegenerationTask = Task { @MainActor in
            defer {
                if isOperationCurrent(
                    generationID,
                    currentID: frameRegenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) {
                    frameRegenerationTask = nil
                    regeneratingSceneID = nil
                }
            }

            guard let imageAccessToken = await auth.freshAccessToken() else {
                guard isOperationCurrent(
                    generationID,
                    currentID: frameRegenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = FruitStoryServiceError.missingAccessToken.localizedDescription
                return
            }
            guard isOperationCurrent(
                generationID,
                currentID: frameRegenerationID,
                lifecycleID: sessionID,
                userID: userID
            ) else { return }

            let referenceImages = [
                ImageGenerationReference(
                    mimeType: "image/png",
                    base64: characterReference
                ),
            ]
            let regenerationPrompt = """
            Storyboard frame \(sceneIndex + 1) of 3, vertical 9:16.
            Use exactly the same single fruit character from the reference.
            \(requestedScene.visualPrompt). Action: \(requestedScene.action).
            Camera: \(requestedScene.camera). No other fruit characters.
            """
            let regenerationFingerprint =
                LiveFruitsImageRequestFingerprint.make(
                    prompt: regenerationPrompt,
                    provider: .gptImage2,
                    category: ImageGenerationCatalog.custom,
                    quantity: 1,
                    size: .portrait,
                    referenceImages: referenceImages
                )
            let regenerationRequestID = imagePendingStore.requestID(
                userID: userID,
                slot: "regenerate.\(requestedScene.id)",
                fingerprint: regenerationFingerprint
            )
            do {
                let response = try await generateImageWithSafeRetry(
                    prompt: regenerationPrompt,
                    referenceImages: referenceImages,
                    idempotencyKey: regenerationRequestID,
                    accessToken: imageAccessToken,
                    operation: .frameRegeneration,
                    generationID: generationID,
                    lifecycleID: sessionID,
                    userID: userID
                )
                let validatedFrame = try validatedImageBase64(response)
                try Task.checkCancellation()
                guard isOperationCurrent(
                    generationID,
                    currentID: frameRegenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }

                frameBase64BySceneID = FruitStoryFrameRegeneration.replacingFrame(
                    sceneID: requestedScene.id,
                    imageBase64: validatedFrame,
                    in: frameBase64BySceneID
                )
                frameFingerprintBySceneID[requestedScene.id] =
                    LiveFruitsFrameLedger.visualFingerprint(for: requestedScene)
                invalidateVideoState()
                imagePendingStore.clear(
                    userID: userID,
                    slot: "regenerate.\(requestedScene.id)",
                    fingerprint: regenerationFingerprint,
                    requestID: regenerationRequestID
                )
            } catch is CancellationError {
                return
            } catch {
                guard isOperationCurrent(
                    generationID,
                    currentID: frameRegenerationID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = "Не удалось пересоздать выбранный кадр. Остальные кадры сохранены."
            }
        }
    }

    private func submitVideo(_ story: FruitStory) {
        guard
            canSubmitVideo,
            let userID = activeUserID,
            UUID(uuidString: userID) != nil,
            isViewActive,
            let firstSceneID = scenes.first?.id,
            let encodedFrame = frameBase64BySceneID[firstSceneID],
            let frame = decodedImage(encodedFrame)
        else { return }

        let startImage: VideoGenerationStartImage
        do {
            startImage = try FruitStoryStartImagePreparer.makeStartImage(from: frame)
        } catch {
            errorMessage = VideoGenerationServiceError.invalidStartImage.localizedDescription
            return
        }

        videoSubmissionTask?.cancel()
        videoRestoreTask?.cancel()
        videoRestoreTask = nil
        videoRestoreID = UUID()
        videoPollTask?.cancel()
        videoPollTask = nil
        videoPollID = UUID()

        let sessionID = lifecycleID
        let generationID = UUID()
        videoSubmissionID = generationID
        let requestedScenes = scenes
        let prompt = FruitStoryVideoPromptBuilder.makePrompt(
            story: story,
            scenes: requestedScenes
        )
        let fingerprint = VideoGenerationInputFingerprint.make(
            prompt: prompt,
            aspectRatio: "9:16",
            durationSeconds: 10,
            startImage: startImage
        )
        let idempotencyKey = localStore.pendingIdempotencyKey(
            for: fingerprint,
            userID: userID
        )

        errorMessage = nil
        isSubmittingVideo = true
        videoJob = nil

        videoSubmissionTask = Task { @MainActor in
            defer {
                if isOperationCurrent(
                    generationID,
                    currentID: videoSubmissionID,
                    lifecycleID: sessionID,
                    userID: userID
                ) {
                    videoSubmissionTask = nil
                    isSubmittingVideo = false
                }
            }

            guard let token = await auth.freshAccessToken() else {
                guard isOperationCurrent(
                    generationID,
                    currentID: videoSubmissionID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = VideoGenerationServiceError.missingAccessToken.localizedDescription
                return
            }
            guard isOperationCurrent(
                generationID,
                currentID: videoSubmissionID,
                lifecycleID: sessionID,
                userID: userID
            ) else { return }

            do {
                let envelope = try await videoService.submit(
                    prompt: prompt,
                    aspectRatio: "9:16",
                    durationSeconds: 10,
                    idempotencyKey: idempotencyKey,
                    startImage: startImage,
                    accessToken: token
                )
                try Task.checkCancellation()
                guard isOperationCurrent(
                    generationID,
                    currentID: videoSubmissionID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }

                localStore.remember(jobID: envelope.job.id, userID: userID)
                localStore.clearPending(
                    acceptedKey: idempotencyKey,
                    userID: userID
                )
                videoJob = envelope.job
                if envelope.job.status == .queued || envelope.job.status == .rendering {
                    startVideoPolling(
                        jobIDs: [envelope.job.id],
                        userID: userID,
                        lifecycleID: sessionID,
                        initialAccessToken: token
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard isOperationCurrent(
                    generationID,
                    currentID: videoSubmissionID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                errorMessage = (error as? VideoGenerationServiceError)?
                    .localizedDescription
                    ?? "Не удалось запустить генерацию видео. Повторите попытку позже."
            }
        }
    }

    private func restoreRecentVideoJobs(
        userID: String,
        lifecycleID sessionID: UUID,
        generationID: UUID
    ) async {
        defer {
            if isOperationCurrent(
                generationID,
                currentID: videoRestoreID,
                lifecycleID: sessionID,
                userID: userID
            ) {
                videoRestoreTask = nil
            }
        }
        guard isOperationCurrent(
            generationID,
            currentID: videoRestoreID,
            lifecycleID: sessionID,
            userID: userID
        ) else { return }

        let jobIDs = localStore.recentJobIDs(userID: userID)
        guard !jobIDs.isEmpty else { return }
        guard let token = await auth.freshAccessToken() else {
            guard isOperationCurrent(
                generationID,
                currentID: videoRestoreID,
                lifecycleID: sessionID,
                userID: userID
            ) else { return }
            errorMessage = VideoGenerationServiceError.missingAccessToken.localizedDescription
            return
        }

        var restoredJob: VideoGenerationJob?
        var activeJobIDs: [String] = []
        for jobID in jobIDs {
            do {
                try Task.checkCancellation()
                guard isOperationCurrent(
                    generationID,
                    currentID: videoRestoreID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }

                let envelope = try await videoService.status(
                    jobID: jobID,
                    accessToken: token
                )
                try Task.checkCancellation()
                guard isOperationCurrent(
                    generationID,
                    currentID: videoRestoreID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }

                if restoredJob == nil {
                    restoredJob = envelope.job
                }
                if envelope.job.status == .queued || envelope.job.status == .rendering {
                    activeJobIDs.append(jobID)
                }
            } catch is CancellationError {
                return
            } catch let serviceError as VideoGenerationServiceError
                where serviceError.makesJobUnavailable {
                guard isOperationCurrent(
                    generationID,
                    currentID: videoRestoreID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                localStore.remove(jobID: jobID, userID: userID)
            } catch {
                activeJobIDs.append(jobID)
            }
        }

        guard isOperationCurrent(
            generationID,
            currentID: videoRestoreID,
            lifecycleID: sessionID,
            userID: userID
        ) else { return }
        videoJob = restoredJob
        if !activeJobIDs.isEmpty {
            startVideoPolling(
                jobIDs: activeJobIDs,
                userID: userID,
                lifecycleID: sessionID,
                initialAccessToken: token
            )
        }
    }

    private func startVideoPolling(
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

        videoPollTask?.cancel()
        let generationID = UUID()
        videoPollID = generationID
        videoPollTask = Task { @MainActor in
            defer {
                if isOperationCurrent(
                    generationID,
                    currentID: videoPollID,
                    lifecycleID: sessionID,
                    userID: userID
                ) {
                    videoPollTask = nil
                }
            }

            var activeJobIDs = uniqueJobIDs
            var token = initialAccessToken
            var retryAttempt = 0
            while !Task.isCancelled && !activeJobIDs.isEmpty {
                do {
                    try await Task.sleep(
                        nanoseconds: VideoGenerationPollingRetryPolicy
                            .delayNanoseconds(attempt: retryAttempt)
                    )
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard isOperationCurrent(
                    generationID,
                    currentID: videoPollID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }

                if token == nil {
                    token = await auth.freshAccessToken()
                }
                guard let currentToken = token else {
                    guard isOperationCurrent(
                        generationID,
                        currentID: videoPollID,
                        lifecycleID: sessionID,
                        userID: userID
                    ) else { return }
                    errorMessage = VideoGenerationServiceError
                        .missingAccessToken.localizedDescription
                    retryAttempt = min(retryAttempt + 1, 3)
                    continue
                }

                var stillActive: [String] = []
                var sawSuccess = false
                for jobID in activeJobIDs {
                    do {
                        let envelope = try await videoService.status(
                            jobID: jobID,
                            accessToken: currentToken
                        )
                        try Task.checkCancellation()
                        guard isOperationCurrent(
                            generationID,
                            currentID: videoPollID,
                            lifecycleID: sessionID,
                            userID: userID
                        ) else { return }

                        sawSuccess = true
                        if videoJob?.id == jobID || videoJob == nil {
                            videoJob = envelope.job
                        }
                        if envelope.job.status == .queued
                            || envelope.job.status == .rendering {
                            stillActive.append(jobID)
                        }
                    } catch is CancellationError {
                        return
                    } catch let serviceError as VideoGenerationServiceError
                        where serviceError.makesJobUnavailable {
                        guard isOperationCurrent(
                            generationID,
                            currentID: videoPollID,
                            lifecycleID: sessionID,
                            userID: userID
                        ) else { return }
                        localStore.remove(jobID: jobID, userID: userID)
                    } catch let serviceError as VideoGenerationServiceError
                        where serviceError.requiresAuthenticationRefresh {
                        guard isOperationCurrent(
                            generationID,
                            currentID: videoPollID,
                            lifecycleID: sessionID,
                            userID: userID
                        ) else { return }
                        stillActive.append(jobID)
                        token = nil
                        errorMessage = serviceError.localizedDescription
                    } catch {
                        guard isOperationCurrent(
                            generationID,
                            currentID: videoPollID,
                            lifecycleID: sessionID,
                            userID: userID
                        ) else { return }
                        stillActive.append(jobID)
                        errorMessage = (error as? VideoGenerationServiceError)?
                            .localizedDescription
                            ?? "Не удалось обновить статус видео. Повторим автоматически."
                    }
                }

                guard isOperationCurrent(
                    generationID,
                    currentID: videoPollID,
                    lifecycleID: sessionID,
                    userID: userID
                ) else { return }
                if sawSuccess {
                    retryAttempt = 0
                    errorMessage = nil
                } else {
                    retryAttempt = min(retryAttempt + 1, 3)
                }
                activeJobIDs = stillActive
            }
        }
    }

    private func generateImageWithSafeRetry(
        prompt: String,
        referenceImages: [ImageGenerationReference],
        idempotencyKey: String,
        accessToken: String,
        operation: ImageOperation,
        generationID: UUID,
        lifecycleID sessionID: UUID,
        userID: String
    ) async throws -> GeneratedImage {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard isImageOperationCurrent(
                operation,
                generationID: generationID,
                lifecycleID: sessionID,
                userID: userID
            ) else {
                throw CancellationError()
            }

            do {
                return try await auth.supabase.generateImageWithAccessToken(
                    prompt: prompt,
                    provider: .gptImage2,
                    category: ImageGenerationCatalog.custom,
                    quantity: 1,
                    size: .portrait,
                    referenceImages: referenceImages,
                    idempotencyKey: idempotencyKey,
                    accessToken: accessToken
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard
                    attempt < 2,
                    isAmbiguousImageTransport(error),
                    isImageOperationCurrent(
                        operation,
                        generationID: generationID,
                        lifecycleID: sessionID,
                        userID: userID
                    )
                else {
                    throw error
                }

                attempt += 1
                try await Task.sleep(
                    nanoseconds: UInt64(attempt * 2) * 1_000_000_000
                )
            }
        }
    }

    private func isAmbiguousImageTransport(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        guard let supabaseError = error as? SupabaseError else { return false }
        switch supabaseError {
        case .invalidResponse:
            return true
        case .serverError(let status, _):
            return status == 425 || (500...599).contains(status)
        case .notAuthenticated, .staleSession, .invalidMediaPayload:
            return false
        }
    }

    private func validatedImageBase64(_ response: GeneratedImage) throws -> String {
        guard decodedImage(response.imageBase64) != nil else {
            throw SupabaseError.invalidResponse
        }
        return response.imageBase64
    }

    private func decodedImage(_ encoded: String) -> UIImage? {
        let raw = encoded.components(separatedBy: ",").last ?? encoded
        guard let data = Data(base64Encoded: raw) else { return nil }
        return UIImage(data: data)
    }

    private func videoStatusTitle(_ status: VideoGenerationJobStatus) -> String {
        switch status {
        case .queued:
            return "Видео в очереди"
        case .rendering:
            return "Видео создаётся"
        case .completed:
            return "Видео готово"
        case .failed:
            return "Не удалось создать видео"
        }
    }
}
