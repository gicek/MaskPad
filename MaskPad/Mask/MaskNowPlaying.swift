import AppKit
import Combine
import MediaRemoteAdapter

@MainActor
protocol MaskMediaControlling: AnyObject {
    var onTrackInfoReceived: ((TrackInfo?) -> Void)? { get set }
    var onListenerTerminated: (() -> Void)? { get set }
    func startListening()
    func stopListening()
    func previousTrack()
    func togglePlayPause()
    func nextTrack()
}

extension MediaController: MaskMediaControlling {}

/// One system Now Playing listener shared by all mask windows, only while the mask is engaged.
@MainActor
final class MaskNowPlaying: ObservableObject {
    @Published private(set) var track: MaskMediaTrack?
    private var controller: (any MaskMediaControlling)?
    private let makeController: () -> any MaskMediaControlling
    private var generation = 0

    init(makeController: @escaping () -> any MaskMediaControlling = { MediaController() }) {
        self.makeController = makeController
    }

    func start() {
        guard controller == nil else { return }
        generation += 1
        let currentGeneration = generation
        let controller = makeController()
        self.controller = controller
        // The package delivers these callbacks on the main queue. Reject already queued updates
        // after dismissal, including when another mask session has since started.
        controller.onTrackInfoReceived = { [weak self] info in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration else { return }
                self.track = info.flatMap { MaskMediaTrack($0.payload) }
            }
        }
        controller.onListenerTerminated = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration else { return }
                self.track = nil
            }
        }
        controller.startListening()
    }

    func stop() {
        generation += 1
        controller?.onTrackInfoReceived = nil
        controller?.onListenerTerminated = nil
        controller?.stopListening()
        controller = nil
        track = nil
    }

    enum Command { case previous, togglePlayback, next }

    func send(_ command: Command) {
        // No session means no controls: sending Play without one can launch a default player.
        guard track != nil, let controller else { return }
        switch command {
        case .previous: controller.previousTrack()
        case .togglePlayback: controller.togglePlayPause()
        case .next: controller.nextTrack()
        }
    }
}

/// A validated snapshot. The progress clock runs locally instead of repeatedly polling the player.
struct MaskMediaTrack {
    let title: String
    let subtitle: String
    let artwork: NSImage?
    let isPlaying: Bool
    let duration: TimeInterval?
    let elapsed: TimeInterval?
    let timestamp: Date?
    let rate: Double

    init?(_ payload: TrackInfo.Payload) {
        guard let title = Self.text(payload.title) else { return nil }
        self.title = title
        subtitle = Self.text(payload.artist) ?? Self.text(payload.applicationName) ?? ""
        artwork = payload.artwork
        isPlaying = payload.isPlaying ?? ((payload.playbackRate ?? 0) > 0)
        duration = Self.seconds(payload.durationMicros).flatMap { $0 > 0 ? $0 : nil }
        elapsed = Self.seconds(payload.elapsedTimeMicros).map { max(0, $0) }
        timestamp = Self.seconds(payload.timestampEpochMicros).map { Date(timeIntervalSince1970: $0) }
        let reportedRate = payload.playbackRate ?? 1
        rate = reportedRate.isFinite ? max(0, reportedRate) : 1
    }

    func position(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        let delta = isPlaying ? timestamp.map { max(0, date.timeIntervalSince($0)) * rate } ?? 0 : 0
        return min(duration ?? .greatestFiniteMagnitude, max(0, elapsed + delta))
    }

    private static func seconds(_ microseconds: Double?) -> Double? {
        guard let microseconds, microseconds.isFinite else { return nil }
        return microseconds / 1_000_000
    }

    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
