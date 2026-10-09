import SwiftUI
import AVKit

/// Plays lesson video. Bunny Stream lessons get a short-lived signed HLS URL
/// from `course-video-playback` (entitlement checked on the server); older
/// lessons keep their direct mp4/HLS URL; YouTube falls back to the browser.
struct LessonPlayerView: View {
    let lesson: CourseLesson
    let courseID: String

    var body: some View {
        VStack(spacing: 0) {
            switch lesson.videoSource {
            case .bunny:
                BunnyLessonVideoLoader(lesson: lesson, courseID: courseID)
            case .direct(let url):
                if Self.isYouTubeURL(url) {
                    YouTubeFallbackView(url: url, title: lesson.title)
                } else {
                    LessonVideoSurface(url: url, refreshURL: nil)
                }
            case .missing:
                ContentUnavailable(systemImage: "play.slash", title: "Video not uploaded yet", subtitle: "This lesson does not have a video yet. Check back soon.")
            }
        }
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .background(Color.black.ignoresSafeArea())
    }

    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
    }
}

/// Requests the signed HLS URL, then hands it to the regular AVPlayer surface.
private struct BunnyLessonVideoLoader: View {
    let lesson: CourseLesson
    let courseID: String

    @EnvironmentObject private var auth: Auth
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case ready(URL)
        case message(icon: String, title: String, subtitle: String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let url):
                LessonVideoSurface(url: url, refreshURL: makeRefresher())
            case let .message(icon, title, subtitle):
                VStack(spacing: 16) {
                    ContentUnavailable(systemImage: icon, title: title, subtitle: subtitle)
                    Button("Повторить") {
                        phase = .loading
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        switch await Self.fetch(auth: auth, courseID: courseID, lessonID: lesson.id) {
        case .ready(let url, _):
            phase = .ready(url)
        case .processing:
            phase = .message(
                icon: "hourglass",
                title: "Видео обрабатывается",
                subtitle: "Готовим качество 1080p/720p/480p. Обычно это занимает несколько минут."
            )
        case .notEntitled:
            phase = .message(
                icon: "lock.fill",
                title: "Урок закрыт",
                subtitle: "Купите курс или этот урок, чтобы смотреть видео."
            )
        case .notAuthenticated:
            phase = .message(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "Нужно войти",
                subtitle: "Войдите в аккаунт, чтобы смотреть этот урок."
            )
        case .failed:
            phase = .message(
                icon: "exclamationmark.triangle",
                title: "Видео не обработалось",
                subtitle: "Автор курса скоро загрузит его заново."
            )
        case .unavailable:
            phase = .message(
                icon: "wifi.exclamationmark",
                title: "Видео временно недоступно",
                subtitle: "Проверьте интернет и повторите."
            )
        }
    }

    /// Captures the environment object while the body is evaluated, so the
    /// player can ask for a fresh signed URL later without touching the view.
    private func makeRefresher() -> CourseVideoPlaybackController.URLRefresher {
        let auth = auth
        let courseID = courseID
        let lessonID = lesson.id
        return {
            let result = await Self.fetch(
                auth: auth,
                courseID: courseID,
                lessonID: lessonID
            )
            if case .ready(let url, _) = result { return url }
            return nil
        }
    }

    private static func fetch(
        auth: Auth,
        courseID: String,
        lessonID: String
    ) async -> CourseVideoPlaybackResult {
        let token = await auth.freshAccessToken(
            invalidateSessionOnCredentialFailure: false
        )
        return await CourseVideoPlaybackClient(
            baseURL: X5Config.supabaseBaseURL,
            anonKey: X5Config.supabaseAnonKey
        ).fetch(
            courseID: courseID,
            lessonID: lessonID,
            accessToken: token
        )
    }
}

/// Сколько места занимают системные полосы управления VideoPlayer сверху и снизу.
/// В точках они одинаковые на всех iPhone, поэтому константа, а не расчёт.
/// идея: если перейти на AVPlayerViewController со своими кнопками — отступы не нужны.
private enum SystemPlayerChrome {
    static let topClearance: CGFloat = 60
    static let bottomClearance: CGFloat = 72
}

/// AVPlayer surface with quality menu, full screen and connection status.
private struct LessonVideoSurface: View {
    @StateObject private var playback: CourseVideoPlaybackController
    @State private var isFullScreenPresented = false
    @State private var viewport = VideoViewportState()

    init(url: URL, refreshURL: CourseVideoPlaybackController.URLRefresher?) {
        _playback = StateObject(
            wrappedValue: CourseVideoPlaybackController(
                url: url,
                refreshURL: refreshURL
            )
        )
    }

    var body: some View {
        ZStack {
            VideoPlayer(player: playback.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    CourseQualityMenu(playback: playback)
                    Spacer()
                    Button {
                        isFullScreenPresented = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 42, height: 42)
                            .background(Color.black.opacity(0.66), in: Circle())
                    }
                    .accessibilityLabel("На весь экран")
                }

                Spacer()

                CoursePlaybackStatus(playback: playback)
            }
            // Системные кнопки VideoPlayer (AirPlay/PiP слева, звук справа сверху, полоса
            // перемотки снизу) стоят в тех же углах — наши «Авто» и «на весь экран» на них
            // наезжали (Адильхан 09.10). Уводим свои кнопки ниже/выше системных полос.
            .padding(.horizontal)
            .padding(.top, SystemPlayerChrome.topClearance)
            .padding(.bottom, SystemPlayerChrome.bottomClearance)
        }
        .background(Color.black)
        .onAppear {
            playback.play()
        }
        .onDisappear {
            if !isFullScreenPresented {
                playback.pause()
            }
        }
        .fullScreenCover(isPresented: $isFullScreenPresented, onDismiss: {
            viewport.reset()
        }) {
            FullScreenVideoPlayer(playback: playback, viewport: $viewport)
        }
    }
}

private struct CourseQualityMenu: View {
    @ObservedObject var playback: CourseVideoPlaybackController

    var body: some View {
        Menu {
            ForEach(playback.availableQualities) { quality in
                Button {
                    playback.selectQuality(quality)
                } label: {
                    if playback.selectedQuality == quality {
                        Label(quality.title, systemImage: "checkmark")
                    } else {
                        Text(quality.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(playback.selectedQualityTitle)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(Color.black.opacity(0.66), in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
        .accessibilityLabel("Качество видео")
        .accessibilityValue(playback.selectedQualityTitle)
    }
}

private struct CoursePlaybackStatus: View {
    @ObservedObject var playback: CourseVideoPlaybackController

    var body: some View {
        VStack(spacing: 10) {
            if playback.isBuffering && !playback.isOffline && playback.playbackError == nil {
                HStack(spacing: 9) {
                    ProgressView()
                        .tint(Color.accentColor)
                    Text("Загружаем видео")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.black.opacity(0.76), in: Capsule())
            }

            if let message = playback.connectionMessage {
                HStack(spacing: 10) {
                    Image(
                        systemName: playback.isOffline
                            ? "wifi.slash"
                            : playback.playbackError == nil
                                ? "exclamationmark.triangle.fill"
                                : "play.slash.fill"
                    )
                    .foregroundColor(
                        playback.isOffline || playback.playbackError != nil
                            ? .red
                            : Color.accentColor
                    )

                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if playback.isOffline || playback.playbackError != nil {
                        Button("Повторить") {
                            playback.retry()
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.accentColor)
                        .disabled(playback.isOffline)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
            }

            if let qualityMessage = playback.sourceQualityMessage,
               playback.connectionMessage == nil,
               !playback.isBuffering {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(Color.accentColor)
                    Text(qualityMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    Color.black.opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
            }
        }
    }
}

/// Полноэкранный плеер урока.
/// Адильхан 09.10 22:30: при зуме видео системные пауза и ползунок увеличивались вместе с картинкой
/// (scaleEffect висел на VideoPlayer целиком), а крестик/«Авто»/сброс торчали посередине и не прятались.
/// Теперь зумится только слой картинки (PlayerLayerView без системных кнопок), а свои кнопки лежат
/// поверх, обычного размера, и прячутся через 3 с — тап по видео показывает их снова.
/// идея: вынести эти кнопки и во встроенный плеер, тогда SystemPlayerChrome станет не нужен.
private struct FullScreenVideoPlayer: View {
    @ObservedObject var playback: CourseVideoPlaybackController
    @Binding var viewport: VideoViewportState

    @Environment(\.dismiss) private var dismiss
    @StateObject private var timeline = PlayerTimeline()
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubSeconds: Double?
    @GestureState private var gestureMagnification: CGFloat = 1
    @GestureState private var gestureTranslation: CGSize = .zero

    private static let skipSeconds = 10.0
    private static let autoHideNanoseconds: UInt64 = 3_000_000_000

    private var displayedScale: CGFloat {
        let proposed = viewport.scale * Double(gestureMagnification)
        return CGFloat(min(max(proposed, VideoViewportState.minimumScale), VideoViewportState.maximumScale))
    }

    private var isZoomed: Bool {
        viewport != VideoViewportState() || displayedScale > CGFloat(VideoViewportState.minimumScale)
    }

    private func displayedTranslation(in viewportSize: CGSize) -> CGSize {
        guard displayedScale > CGFloat(VideoViewportState.minimumScale) else { return .zero }
        let clamped = viewport.clampedTranslation(
            x: Double(CGFloat(viewport.translationX) + gestureTranslation.width),
            y: Double(CGFloat(viewport.translationY) + gestureTranslation.height),
            scale: Double(displayedScale),
            viewportWidth: Double(viewportSize.width),
            viewportHeight: Double(viewportSize.height)
        )
        return CGSize(
            width: CGFloat(clamped.x),
            height: CGFloat(clamped.y)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                // Зум и сдвиг — только у картинки. Кнопки ниже в ZStack не масштабируются.
                PlayerLayerView(player: playback.player)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(displayedScale)
                    .offset(displayedTranslation(in: proxy.size))
                    .allowsHitTesting(false)

                // Слой жестов под кнопками: щипок — зум, палец — сдвиг, тап — кнопки, двойной тап — сброс.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(tapGestures)
                    .simultaneousGesture(magnificationGesture(in: proxy.size))
                    .simultaneousGesture(translationGesture(in: proxy.size))

                controls(in: proxy)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .animation(.easeInOut(duration: 0.2), value: controlsVisible)

                // Ошибки и «Загружаем видео» видны всегда, даже когда кнопки спрятаны.
                VStack {
                    Spacer()
                    CoursePlaybackStatus(playback: playback)
                        .padding(.horizontal, 16)
                        .padding(.bottom, proxy.safeAreaInsets.bottom + (controlsVisible ? 86 : 20))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onChange(of: proxy.size) { newSize in
                viewport.clampTranslation(
                    viewportWidth: Double(newSize.width),
                    viewportHeight: Double(newSize.height)
                )
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            AppOrientationCoordinator.enterVideoFullscreen()
            timeline.attach(to: playback.player)
            playback.play()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            timeline.detach()
            AppOrientationCoordinator.leaveVideoFullscreen()
        }
        .onChange(of: timeline.isPlaying) { _ in
            scheduleHide()
        }
    }

    // MARK: - Кнопки

    private func controls(in proxy: GeometryProxy) -> some View {
        ZStack {
            // Тёмные полосы сверху и снизу, чтобы белые кнопки читались на светлом видео.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    roundButton(systemName: "xmark", label: "Close") {
                        dismiss()
                    }

                    Spacer()

                    CourseQualityMenu(playback: playback)

                    // Сброс зума нужен только когда видео увеличено — иначе это лишняя кнопка (скрин 22:29).
                    if isZoomed {
                        roundButton(systemName: "arrow.counterclockwise", label: "Reset zoom") {
                            viewport.reset()
                            scheduleHide()
                        }
                    }
                }
                .padding(.leading, max(16, proxy.safeAreaInsets.leading))
                .padding(.trailing, max(16, proxy.safeAreaInsets.trailing))
                .padding(.top, max(12, proxy.safeAreaInsets.top))

                Spacer()

                HStack(spacing: 44) {
                    roundButton(systemName: "gobackward.10", label: "Назад 10 секунд", size: 54) {
                        timeline.skip(by: -Self.skipSeconds)
                        scheduleHide()
                    }
                    roundButton(
                        systemName: timeline.isPlaying ? "pause.fill" : "play.fill",
                        label: timeline.isPlaying ? "Пауза" : "Смотреть",
                        size: 70
                    ) {
                        togglePlayback()
                    }
                    roundButton(systemName: "goforward.10", label: "Вперёд 10 секунд", size: 54) {
                        timeline.skip(by: Self.skipSeconds)
                        scheduleHide()
                    }
                }

                Spacer()

                if timeline.durationSeconds > 0 {
                    HStack(spacing: 12) {
                        Text(Self.timeText(scrubSeconds ?? timeline.currentSeconds))
                        Slider(
                            value: Binding(
                                get: { min(scrubSeconds ?? timeline.currentSeconds, timeline.durationSeconds) },
                                set: { scrubSeconds = $0 }
                            ),
                            in: 0...timeline.durationSeconds,
                            onEditingChanged: { editing in
                                if editing {
                                    hideTask?.cancel()
                                } else if let target = scrubSeconds {
                                    timeline.seek(to: target)
                                    scrubSeconds = nil
                                    scheduleHide()
                                }
                            }
                        )
                        .tint(Color.accentColor)
                        Text(Self.timeText(timeline.durationSeconds))
                    }
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
                    .padding(.leading, max(20, proxy.safeAreaInsets.leading))
                    .padding(.trailing, max(20, proxy.safeAreaInsets.trailing))
                    .padding(.bottom, max(16, proxy.safeAreaInsets.bottom))
                }
            }
        }
    }

    private func roundButton(
        systemName: String,
        label: String,
        size: CGFloat = 42,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.58), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func togglePlayback() {
        if timeline.isPlaying {
            playback.pause()
        } else {
            // Досмотрел до конца — «Смотреть» начинает сначала, а не стоит на последнем кадре.
            if timeline.durationSeconds > 0, timeline.currentSeconds >= timeline.durationSeconds - 0.5 {
                timeline.seek(to: 0)
            }
            playback.play()
        }
        scheduleHide()
    }

    /// Кнопки прячутся через 3 с, только пока видео идёт и ползунок не держат.
    private func scheduleHide() {
        hideTask?.cancel()
        guard timeline.isPlaying, scrubSeconds == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.autoHideNanoseconds)
            guard !Task.isCancelled, timeline.isPlaying, scrubSeconds == nil else { return }
            controlsVisible = false
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Жесты

    private var tapGestures: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                viewport.reset()
            }
            .exclusively(before: TapGesture(count: 1).onEnded {
                controlsVisible.toggle()
                if controlsVisible {
                    scheduleHide()
                } else {
                    hideTask?.cancel()
                }
            })
    }

    private func magnificationGesture(in viewportSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($gestureMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                viewport.applyMagnification(
                    viewport.scale * Double(value),
                    viewportWidth: Double(viewportSize.width),
                    viewportHeight: Double(viewportSize.height)
                )
            }
    }

    private func translationGesture(in viewportSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($gestureTranslation) { value, state, _ in
                guard viewport.scale > VideoViewportState.minimumScale else { return }
                state = value.translation
            }
            .onEnded { value in
                guard viewport.scale > VideoViewportState.minimumScale else { return }
                viewport.applyTranslation(
                    x: viewport.translationX + Double(value.translation.width),
                    y: viewport.translationY + Double(value.translation.height),
                    viewportWidth: Double(viewportSize.width),
                    viewportHeight: Double(viewportSize.height)
                )
            }
    }
}

/// Время и состояние плеера для своих кнопок полноэкранного режима.
@MainActor
private final class PlayerTimeline: ObservableObject {
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var isPlaying = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    func attach(to player: AVPlayer) {
        detach()
        self.player = player
        refresh(time: player.currentTime())
        isPlaying = player.timeControlStatus != .paused
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.refresh(time: time)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            // «Ждёт сеть» считаем игрой: кнопка показывает паузу, как в системном плеере.
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in
                self?.isPlaying = playing
            }
        }
    }

    func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
    }

    func skip(by seconds: Double) {
        let upper = durationSeconds > 0 ? durationSeconds : .greatestFiniteMagnitude
        seek(to: min(max(currentSeconds + seconds, 0), upper))
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        // Сразу двигаем цифры, чтобы ползунок не прыгал назад, пока плеер ищет кадр.
        currentSeconds = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func refresh(time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite {
            currentSeconds = max(seconds, 0)
        }
        // У HLS длительность приходит не сразу; у живого потока её нет — тогда ползунок скрыт.
        if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            durationSeconds = duration
        }
    }
}

/// Голая картинка AVPlayer без системных кнопок — её можно зумить, не трогая управление.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PlayerLayerContainerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

private final class PlayerLayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = newValue
        }
    }
}

private struct YouTubeFallbackView: View {
    let url: URL
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                UIApplication.shared.open(url)
            } label: {
                Text("Open on YouTube")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct ContentUnavailable: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white.opacity(0.7))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
