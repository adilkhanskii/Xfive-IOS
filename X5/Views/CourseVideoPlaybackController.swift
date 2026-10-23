import AVFoundation
import Combine
import Foundation
import Network

enum CourseVideoQuality: String, CaseIterable, Identifiable {
    case automatic
    case p360
    case p480
    case p720
    case p1080
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Авто"
        case .p360: return "360p"
        case .p480: return "480p"
        case .p720: return "720p HD"
        case .p1080: return "1080p Full HD"
        case .original: return "Оригинал"
        }
    }

    fileprivate var preferredPeakBitRate: Double {
        switch self {
        case .automatic, .original: return 0
        case .p360: return 800_000
        case .p480: return 1_400_000
        case .p720: return 3_000_000
        case .p1080: return 6_000_000
        }
    }

    fileprivate var maximumResolution: CGSize {
        switch self {
        case .automatic, .original: return .zero
        case .p360: return CGSize(width: 640, height: 360)
        case .p480: return CGSize(width: 854, height: 480)
        case .p720: return CGSize(width: 1280, height: 720)
        case .p1080: return CGSize(width: 1920, height: 1080)
        }
    }
}

@MainActor
final class CourseVideoPlaybackController: ObservableObject {
    let player: AVPlayer
    let isAdaptiveStream: Bool

    @Published private(set) var selectedQuality: CourseVideoQuality
    @Published private(set) var isBuffering = true
    @Published private(set) var isOffline = false
    @Published private(set) var showsWeakConnection = false
    @Published private(set) var playbackError: String?
    @Published private(set) var sourceQualityLabel: String?
    @Published private(set) var sourceQualityIsLow = false

    var availableQualities: [CourseVideoQuality] {
        isAdaptiveStream
            ? [.automatic, .p360, .p480, .p720, .p1080]
            : [.original]
    }

    var connectionMessage: String? {
        if isOffline { return "Нет интернета. Проверьте соединение и повторите." }
        if let playbackError { return playbackError }
        if showsWeakConnection {
            return selectedQuality == .automatic
                ? "Слабое соединение — качество снижается автоматически."
                : "Слабое соединение — выберите «Авто» или 360p."
        }
        return nil
    }

    var selectedQualityTitle: String {
        guard selectedQuality == .original,
              let sourceQualityLabel
        else {
            return selectedQuality.title
        }
        return "\(sourceQualityLabel) · исходник"
    }

    var sourceQualityMessage: String? {
        guard sourceQualityIsLow, let sourceQualityLabel else { return nil }
        return "Исходный файл — \(sourceQualityLabel). Для чёткого видео замените его исходником минимум 720p."
    }

    typealias URLRefresher = () async -> URL?

    private var sourceURL: URL?
    /// Signed Bunny HLS URLs expire; the refresher asks the playback
    /// function for a new one when the item fails or the user retries.
    private let refreshURL: URLRefresher?
    private var lastAutomaticRefresh: Date?
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "x5.course.video.network")
    private var playerObservation: NSKeyValueObservation?
    private var itemObservations: [NSKeyValueObservation] = []
    private var bufferingTask: Task<Void, Never>?

    init(url: URL?, refreshURL: URLRefresher? = nil) {
        let resolvedURL = Self.resolvedPlaybackURL(url)
        sourceURL = resolvedURL
        self.refreshURL = refreshURL
        isAdaptiveStream = resolvedURL?.pathExtension.lowercased() == "m3u8"
        selectedQuality = isAdaptiveStream ? .automatic : .original

        if let url = resolvedURL {
            let item = Self.makePlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
        } else {
            player = AVPlayer()
            isBuffering = false
        }

        observePlayer()
        observeCurrentItem()
        startNetworkMonitoring()
        inspectSourceQuality()
    }

    deinit {
        bufferingTask?.cancel()
        pathMonitor.cancel()
        playerObservation?.invalidate()
        itemObservations.forEach { $0.invalidate() }
    }

    func play() {
        guard sourceURL != nil else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func selectQuality(_ quality: CourseVideoQuality) {
        guard availableQualities.contains(quality) else { return }
        selectedQuality = quality
        applyQuality(to: player.currentItem)
    }

    func retry() {
        guard sourceURL != nil, !isOffline else { return }
        let resumeTime = player.currentTime()
        playbackError = nil
        showsWeakConnection = false
        isBuffering = true

        if let refreshURL {
            Task { [weak self] in
                let fresh = await refreshURL()
                guard let self else { return }
                if let fresh { self.sourceURL = fresh }
                self.reload(resumeTime: resumeTime)
            }
            return
        }
        reload(resumeTime: resumeTime)
    }

    private func reload(resumeTime: CMTime) {
        guard let sourceURL else { return }
        let item = Self.makePlayerItem(url: sourceURL)
        player.replaceCurrentItem(with: item)
        applyQuality(to: item)
        observeCurrentItem()

        if resumeTime.isValid && resumeTime.seconds.isFinite && resumeTime.seconds > 0 {
            player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    private static func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        return item
    }

    private static func resolvedPlaybackURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.host?.lowercased() == "iframe.mediadelivery.net",
              let videoID = url.pathComponents.last,
              UUID(uuidString: videoID) != nil
        else {
            return url
        }

        return URL(
            string: "https://vz-d2ffe898-fa1.b-cdn.net/\(videoID.lowercased())/playlist.m3u8"
        )
    }

    private func applyQuality(to item: AVPlayerItem?) {
        guard isAdaptiveStream, let item else { return }
        item.preferredPeakBitRate = selectedQuality.preferredPeakBitRate
        item.preferredMaximumResolution = selectedQuality.maximumResolution
    }

    private func inspectSourceQuality() {
        guard !isAdaptiveStream, let sourceURL else { return }
        Task { [weak self] in
            let asset = AVURLAsset(url: sourceURL)
            guard let tracks = try? await asset.loadTracks(
                withMediaType: .video
            ),
                  let track = tracks.first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let preferredTransform = try? await track.load(
                    .preferredTransform
                  )
            else {
                return
            }
            let presentationRect = CGRect(
                origin: .zero,
                size: naturalSize
            ).applying(preferredTransform)
            let shortSide = min(
                abs(presentationRect.width),
                abs(presentationRect.height)
            )
            guard shortSide.isFinite, shortSide > 0 else { return }
            let height = Int(shortSide.rounded())
            let label: String
            switch height {
            case 1_080...: label = "1080p"
            case 720...: label = "720p"
            case 480...: label = "480p"
            case 360...: label = "360p"
            default: label = "\(height)p"
            }
            await MainActor.run { [weak self] in
                self?.sourceQualityLabel = label
                self?.sourceQualityIsLow = height < 720
            }
        }
    }

    private func observePlayer() {
        playerObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatus(player.timeControlStatus)
            }
        }
    }

    private func observeCurrentItem() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        guard let item = player.currentItem else { return }

        itemObservations.append(
            item.observe(\.status, options: [.initial, .new]) {
                [weak self] item, _ in
                Task { @MainActor [weak self] in
                    guard item.status == .failed, let self else { return }
                    // A signed URL may have expired mid-lesson: fetch a new
                    // one once per minute before showing an error.
                    if self.refreshURL != nil,
                       !self.isOffline,
                       (self.lastAutomaticRefresh.map {
                           Date().timeIntervalSince($0) > 60
                       } ?? true) {
                        self.lastAutomaticRefresh = Date()
                        self.retry()
                        return
                    }
                    self.playbackError =
                        "Видео не загрузилось. Нажмите «Повторить»."
                    self.isBuffering = false
                }
            }
        )
        itemObservations.append(
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) {
                [weak self] item, _ in
                guard item.isPlaybackBufferEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.beginBuffering()
                }
            }
        )
        itemObservations.append(
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) {
                [weak self] item, _ in
                guard item.isPlaybackLikelyToKeepUp else { return }
                Task { @MainActor [weak self] in
                    self?.finishBuffering()
                }
            }
        )
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            beginBuffering()
        case .playing:
            finishBuffering()
        case .paused:
            if player.currentItem?.status == .readyToPlay {
                isBuffering = false
            }
        @unknown default:
            break
        }
    }

    private func beginBuffering() {
        isBuffering = true
        bufferingTask?.cancel()
        bufferingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isBuffering, !self.isOffline else { return }
                self.showsWeakConnection = true
            }
        }
    }

    private func finishBuffering() {
        bufferingTask?.cancel()
        bufferingTask = nil
        isBuffering = false
        if !isOffline {
            showsWeakConnection = false
        }
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = self.isOffline
                self.isOffline = offline
                if offline {
                    self.bufferingTask?.cancel()
                    self.isBuffering = false
                    self.showsWeakConnection = false
                } else {
                    self.showsWeakConnection = constrained
                    if wasOffline, self.playbackError == nil {
                        self.retry()
                    }
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
}
