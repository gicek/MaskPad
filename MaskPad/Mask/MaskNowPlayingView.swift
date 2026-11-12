import SwiftUI

/// A quiet companion to the status row. Artwork supplies the only color on the black mask.
struct MaskNowPlayingView: View {
    @ObservedObject var media: MaskNowPlaying
    @ObservedObject private var settings = MaskSettings.shared
    var width: CGFloat = 324

    var body: some View {
        if settings.showsNowPlaying, let track = media.track {
            MaskNowPlayingCard(track: track, width: width, showsControls: settings.showsPlaybackControls) { command in
                if MaskInputOrigin.currentEventIsPersonPress() { media.send(command) }
            }
        }
    }
}

struct MaskNowPlayingCard: View {
    let track: MaskMediaTrack
    var width: CGFloat = 324
    var showsControls = true
    var progressDate: Date? = nil
    let onCommand: (MaskNowPlaying.Command) -> Void
    private var isCompact: Bool { width < 280 }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                if !isCompact { artwork }
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(isCompact ? 1 : 2)
                    if !track.subtitle.isEmpty {
                        Text(verbatim: track.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Image(systemName: track.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityLabel(track.isPlaying ? L("Now playing") : L("Paused"))
                    .accessibilityHidden(!isCompact || !showsControls)
                if !isCompact || !showsControls {
                    Text(track.isPlaying ? L("Now playing") : L("Paused"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                if showsControls {
                    HStack(spacing: 4) {
                        // Video and browsers: play/pause only (`MaskMediaSource`).
                        if track.allowsSkipping {
                            control("backward.end.fill", label: L("Previous track"), command: .previous)
                        }
                        control(track.isPlaying ? "pause.fill" : "play.fill",
                                label: track.isPlaying ? L("Pause") : L("Play"), command: .togglePlayback, primary: true)
                        if track.allowsSkipping {
                            control("forward.end.fill", label: L("Next track"), command: .next)
                        }
                    }
                }
            }

            if !isCompact, let duration = track.duration, track.elapsed != nil {
                TimelineView(.animation(minimumInterval: 1, paused: !track.isPlaying || progressDate != nil)) { context in
                    let position = track.position(at: progressDate ?? context.date) ?? 0
                    VStack(spacing: 7) {
                        GeometryReader { geometry in
                            Capsule().fill(.white.opacity(0.1))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.55))
                                        .frame(width: geometry.size.width * min(1, max(0, position / duration)))
                                }
                        }
                        .frame(height: 3)
                        .accessibilityLabel(L("Playback progress"))
                        .accessibilityValue(Text("\(Int(position / duration * 100))%"))
                        HStack {
                            Text(Self.time(position))
                            Spacer()
                            Text(Self.time(duration))
                        }
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.065)))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
            if let image = track.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private func control(_ symbol: String, label: String, command: MaskNowPlaying.Command, primary: Bool = false) -> some View {
        Button { onCommand(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: primary ? 16 : 13, weight: .semibold))
                .offset(x: symbol == "play.fill" ? 1 : 0)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(MediaControlStyle(primary: primary))
        .accessibilityLabel(label)
        .help(label)
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let seconds = Int(min(359_999, max(0, seconds)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MediaControlStyle: ButtonStyle {
    let primary: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.22 : isHovered ? 0.16 : primary ? 0.1 : 0)))
            .onHover { isHovered = $0 }
    }
}
