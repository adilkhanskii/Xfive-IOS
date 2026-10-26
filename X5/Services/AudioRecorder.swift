import Foundation
import AVFoundation

/// Lightweight wrapper around AVAudioRecorder for press-and-hold voice messages
/// in chats. Records mono AAC at 32kbps to a temporary .m4a file.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var recordingURL: URL?
    /// Сколько секунд идёт запись — для таймера «0:07» в поле ввода (Адильхан 12.10: «надо таймер добавить»).
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var ticker: Timer?
    // Чат — 32 кГц / 32 кбит/с; образец для клона голоса пишем чище (44.1 кГц / 128 кбит/с).
    private let sampleRate: Int
    private let bitRate: Int

    init(sampleRate: Int = 32_000, bitRate: Int = 32_000) {
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        super.init()
    }
    private var isStarting = false
    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        // Request mic permission if not yet granted.
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            session.requestRecordPermission { ok in cont.resume(returning: ok) }
        }
        guard !isRecording else { return }
        guard granted else {
            permissionDenied = true
            return
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString.prefix(6)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: (bitRate > 32_000 ? AVAudioQuality.high : AVAudioQuality.medium).rawValue,
            AVEncoderBitRateKey: bitRate
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            recordingURL = url
            elapsed = 0
            isRecording = true
            startTicker()
        } catch {
            isRecording = false
        }
    }

    /// Stops recording. Returns (data, mime, ext, duration) for upload, or nil if nothing recorded.
    /// duration идёт в текст сообщения («4s», как пишет сайт): у собеседника длина видна сразу, а не «0:00 / 0:00».
    @discardableResult
    func stop() -> (data: Data, mime: String, ext: String, duration: TimeInterval)? {
        guard let r = recorder, let url = recordingURL else { return nil }
        let duration = r.currentTime
        recorder = nil
        recordingURL = nil
        r.stop()
        stopTicker()
        isRecording = false
        try? session.setActive(false)
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return (data, "audio/mp4", "m4a", duration)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        stopTicker()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        isRecording = false
        elapsed = 0
        try? session.setActive(false)
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                self.elapsed = r.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
