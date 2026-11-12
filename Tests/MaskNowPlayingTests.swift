import Foundation
import MediaRemoteAdapter
import Testing
@testable import MaskPad

struct MaskNowPlayingTests {
    @Test @MainActor func listenerLifetimeAndControls() throws {
        let controller = TestMediaController()
        var instances = 0
        let media = MaskNowPlaying {
            instances += 1
            return controller
        }
        media.start()
        media.start()
        #expect(instances == 1)
        #expect(controller.starts == 1)
        media.send(.togglePlayback)
        #expect(controller.commands.isEmpty)

        let queuedUpdate = try #require(controller.onTrackInfoReceived)
        queuedUpdate(TrackInfo(payload: .init(title: "Song", isPlaying: true)))
        #expect(media.track?.title == "Song")
        media.send(.previous)
        media.send(.togglePlayback)
        media.send(.next)
        #expect(controller.commands == ["previous", "toggle", "next"])
        controller.onListenerTerminated?()
        #expect(media.track == nil)
        media.send(.next)
        #expect(controller.commands.count == 3)

        media.stop()
        #expect(controller.stops == 1)
        #expect(controller.onTrackInfoReceived == nil)
        queuedUpdate(TrackInfo(payload: .init(title: "Stale song")))
        #expect(media.track == nil)
        media.start()
        queuedUpdate(TrackInfo(payload: .init(title: "Previous session")))
        #expect(media.track == nil)
        controller.onTrackInfoReceived?(TrackInfo(payload: .init(title: "New session")))
        #expect(media.track?.title == "New session")
        controller.onTrackInfoReceived?(nil)
        #expect(media.track == nil)
        media.stop()
    }

    @Test func emptySessionsAreHidden() {
        #expect(MaskMediaTrack(.init()) == nil)
        #expect(MaskMediaTrack(.init(title: " \n ", isPlaying: true)) == nil)
    }

    @Test func trimsMetadataAndFallsBackToPlayerName() throws {
        let track = try #require(MaskMediaTrack(.init(title: " Song \n", artist: " ", applicationName: " Safari ")))
        #expect(track.title == "Song")
        #expect(track.subtitle == "Safari")
        let artist = try #require(MaskMediaTrack(.init(title: "Song", artist: "Artist", applicationName: "Music")))
        #expect(artist.subtitle == "Artist")
    }

    @Test func playingProgressUsesSnapshotTimestampAndRate() throws {
        let track = try #require(MaskMediaTrack(.init(
            title: "Song", isPlaying: true, durationMicros: 200_000_000,
            elapsedTimeMicros: 30_000_000, timestampEpochMicros: 1_000_000_000, playbackRate: 2
        )))
        #expect(track.position(at: Date(timeIntervalSince1970: 1010)) == 50)
        #expect(track.position(at: Date(timeIntervalSince1970: 2000)) == 200)
        #expect(track.position(at: Date(timeIntervalSince1970: 900)) == 30)
    }

    @Test func pausedProgressDoesNotAdvance() throws {
        let track = try #require(MaskMediaTrack(.init(
            title: "Song", isPlaying: false, durationMicros: 200_000_000,
            elapsedTimeMicros: 30_000_000, timestampEpochMicros: 1_000_000_000, playbackRate: 1
        )))
        #expect(track.position(at: Date(timeIntervalSince1970: 2000)) == 30)
    }

    @Test func missingTimingAndInvalidValuesAreSafe() throws {
        let live = try #require(MaskMediaTrack(.init(title: "Live radio", isPlaying: true)))
        #expect(live.duration == nil)
        #expect(live.position(at: .now) == nil)
        let invalid = try #require(MaskMediaTrack(.init(
            title: "Song", durationMicros: .infinity, elapsedTimeMicros: .nan,
            timestampEpochMicros: .nan, playbackRate: .infinity
        )))
        #expect(invalid.duration == nil)
        #expect(invalid.position(at: .now) == nil)
        #expect(invalid.rate == 1)
        let unknownDuration = try #require(MaskMediaTrack(.init(
            title: "Stream", durationMicros: -1, elapsedTimeMicros: -1, playbackRate: 1
        )))
        #expect(unknownDuration.isPlaying)
        #expect(unknownDuration.duration == nil)
        #expect(unknownDuration.position(at: .now) == 0)
    }
}

@MainActor
private final class TestMediaController: MaskMediaControlling {
    var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    var onListenerTerminated: (() -> Void)?
    var starts = 0
    var stops = 0
    var commands: [String] = []
    func startListening() { starts += 1 }
    func stopListening() { stops += 1 }
    func previousTrack() { commands.append("previous") }
    func togglePlayPause() { commands.append("toggle") }
    func nextTrack() { commands.append("next") }
}
