import AppKit
import Combine
import os
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
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var generation = 0
    /// Listener restarts left in this mask session (`maxRestarts`).
    private var restartsLeft = 0

    /// A listener that quits while masked (the helper crashed or was killed) is started again after
    /// `restartDelay`: Settings can't be reached under the mask to turn the card off and on. At most
    /// `maxRestarts` times per session, so a helper that can't run doesn't loop.
    static let restartDelay: TimeInterval = 2
    static let maxRestarts = 3

    init(
        makeController: @escaping () -> any MaskMediaControlling = { MediaController() },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    ) {
        self.makeController = makeController
        self.schedule = schedule
    }

    func start() {
        guard controller == nil else { return }
        restartsLeft = Self.maxRestarts
        listen()
    }

    private func listen() {
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
                self.listenerTerminated()
            }
        }
        controller.startListening()
    }

    private func listenerTerminated() {
        track = nil
        controller?.onTrackInfoReceived = nil
        controller?.onListenerTerminated = nil
        controller = nil
        // A new generation, so the queued restart is dropped if the mask turns off meanwhile.
        generation += 1
        guard restartsLeft > 0 else { return }
        restartsLeft -= 1
        let currentGeneration = generation
        schedule(Self.restartDelay) { [weak self] in
            guard let self, self.generation == currentGeneration, self.controller == nil else { return }
            self.listen()
        }
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
        guard let track, let controller else { return }
        guard command == .togglePlayback || track.allowsSkipping else { return }
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
    /// Whether Previous and Next are offered (`MaskMediaSource`).
    let allowsSkipping: Bool

    init?(_ payload: TrackInfo.Payload, isWebBrowser: (String) -> Bool = MaskMediaSource.isWebBrowser) {
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
        allowsSkipping = MaskMediaSource.allowsSkipping(bundleID: payload.bundleIdentifier, isWebBrowser: isWebBrowser)
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

/// Which players get Previous and Next on the mask. Only play/pause for video: in a browser, Next goes to
/// another video or page, and a video player moves to another file, which can break what a tool under the
/// mask is doing with that window. Music players keep all three.
///
/// Now Playing doesn't say whether a session is video, so it goes by the player: web browsers (any app
/// that opens http and https links, and well-known browsers by bundle ID, which also covers their helper
/// processes) and well-known video players. An unknown source gets only play/pause.
enum MaskMediaSource {
    static let browserPrefixes = [
        "com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.chromium.", "org.mozilla.",
        "com.microsoft.edgemac", "company.thebrowser.", "com.brave.Browser", "com.operasoftware.",
        "com.vivaldi.", "app.zen-browser.", "com.kagi.kagimacOS",
    ]

    static let videoPlayers: Set<String> = [
        "com.apple.QuickTimePlayerX", "com.apple.TV", "com.colliderli.iina", "org.videolan.vlc",
        "io.mpv", "com.firecore.infuse", "com.movist.MovistPro", "com.netflix.Netflix",
    ]

    static func allowsSkipping(bundleID: String?, isWebBrowser: (String) -> Bool) -> Bool {
        guard let bundleID, bundleID.isEmpty == false else { return false }
        if videoPlayers.contains(bundleID) { return false }
        if browserPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return false }
        return isWebBrowser(bundleID) == false
    }

    /// Whether the app declares itself a handler for web links. Read from its Info.plist, once per app.
    static func isWebBrowser(_ bundleID: String) -> Bool {
        cacheLock.withLock { cache in
            if let known = cache[bundleID] { return known }
            let isBrowser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] }
                .map { types in
                    types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains { ["http", "https"].contains($0.lowercased()) } ?? false }
                } ?? false
            cache[bundleID] = isBrowser
            return isBrowser
        }
    }

    private static let cacheLock = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
}
