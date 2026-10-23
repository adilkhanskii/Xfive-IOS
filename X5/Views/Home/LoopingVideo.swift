import AVFoundation
import SwiftUI

enum HomeMotionSource: Equatable {
    case bundled(resourceName: String)
    case remote(url: URL)
}

struct HomeMotionAsset: Equatable {
    let source: HomeMotionSource
    let posterAssetName: String
}

enum HomeMotionCatalog {
    static func asset(for imageAssetName: String) -> HomeMotionAsset? {
        switch imageAssetName {
        case "HomeCoverTargetAds",
             "HomeUtilityVideo",
             "HomeMotionStudioPoster":
            return HomeMotionAsset(
                source: .bundled(resourceName: "HomeMotionStudio"),
                posterAssetName: "HomeMotionStudioPoster"
            )
        case "HomeTrendFruitVideo":
            return HomeMotionAsset(
                source: .bundled(resourceName: "HomeMotionFruit"),
                posterAssetName: "HomeMotionFruitPoster"
            )
        case "HomeTrendLiveVideo":
            return HomeMotionAsset(
                source: .bundled(resourceName: "HomeTrendStrawberry"),
                posterAssetName: "HomeTrendLiveVideo"
            )
        case "HomeTrendPost":
            return HomeMotionAsset(
                source: .bundled(resourceName: "HomeTrendTokayev"),
                posterAssetName: "HomeTrendPost"
            )
        default:
            return nil
        }
    }
}

enum HomeMotionPlaybackPolicy {
    static func shouldPlay(
        isActive: Bool,
        isVisible: Bool,
        appIsActive: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        isUserInitiated: Bool = false
    ) -> Bool {
        isActive
            && isVisible
            && appIsActive
            && (isUserInitiated || (!reduceMotion && !lowPowerMode))
    }
}

/// Muted card motion backed by one ordinary AVPlayer.
/// The poster always remains underneath, so a missing or failed video is harmless.
struct LoopingVideo: View {
    let source: HomeMotionSource
    let posterAssetName: String?
    let isActive: Bool
    let isUserInitiated: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var controller: HomeLoopingVideoController
    @State private var isVisible = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    init(
        source: HomeMotionSource,
        posterAssetName: String? = nil,
        isActive: Bool,
        isUserInitiated: Bool = false
    ) {
        self.source = source
        self.posterAssetName = posterAssetName
        self.isActive = isActive
        self.isUserInitiated = isUserInitiated
        _controller = StateObject(
            wrappedValue: HomeLoopingVideoController(source: source)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let posterAssetName {
                    Image(posterAssetName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }

                if controller.isReady, let player = controller.player {
                    HomePlayerLayerView(player: player)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
        }
        .background(Color.white.opacity(0.06))
        .onGeometryChange(for: Bool.self) { proxy in
            let frame = proxy.frame(in: .global)
            let screen = UIScreen.main.bounds.insetBy(dx: 0, dy: -32)
            return frame.width > 0
                && frame.height > 0
                && frame.intersects(screen)
        } action: { isVisible in
            self.isVisible = isVisible
        }
        .onAppear {
            controller.setShouldPlay(playbackShouldRun)
        }
        .onDisappear {
            isVisible = false
            controller.setShouldPlay(false)
        }
        .onChange(of: playbackShouldRun) { shouldPlay in
            controller.setShouldPlay(shouldPlay)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private var playbackShouldRun: Bool {
        HomeMotionPlaybackPolicy.shouldPlay(
            isActive: isActive,
            isVisible: isVisible,
            appIsActive: scenePhase == .active,
            reduceMotion: reduceMotion,
            lowPowerMode: lowPowerMode,
            isUserInitiated: isUserInitiated
        )
    }
}

private final class HomeLoopingVideoController: ObservableObject {
    @Published private(set) var isReady = false
    private(set) var player: AVPlayer?

    private var shouldPlay = false
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init(source: HomeMotionSource, bundle: Bundle = .main) {
        guard let url = Self.mediaURL(for: source, bundle: bundle) else {
            return
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReady = item.status == .readyToPlay
                self.applyPlaybackState()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player?.seek(to: .zero)
            self.applyPlaybackState()
        }
    }

    deinit {
        statusObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    func setShouldPlay(_ shouldPlay: Bool) {
        self.shouldPlay = shouldPlay
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        guard shouldPlay, isReady else {
            player?.pause()
            return
        }
        player?.play()
    }

    private static func mediaURL(
        for source: HomeMotionSource,
        bundle: Bundle
    ) -> URL? {
        switch source {
        case .bundled(let resourceName):
            return bundle.url(
                forResource: resourceName,
                withExtension: "mp4",
                subdirectory: "HomeMotion"
            ) ?? bundle.url(forResource: resourceName, withExtension: "mp4")
        case .remote(let url):
            guard url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "afwznqjpshybmqhlewmy.supabase.co",
                  url.path.hasPrefix("/storage/v1/object/public/videos/home/")
            else {
                return nil
            }
            return url
        }
    }
}

private struct HomePlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> HomePlayerContainerView {
        let view = HomePlayerContainerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: HomePlayerContainerView, context: Context) {
        uiView.player = player
    }

    static func dismantleUIView(_ uiView: HomePlayerContainerView, coordinator: ()) {
        uiView.player = nil
    }
}

private final class HomePlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.player = newValue
        }
    }
}
