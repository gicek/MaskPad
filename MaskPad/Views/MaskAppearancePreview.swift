import SwiftUI

/// A read-only miniature of the mask. It never starts media, authentication, or input-blocking services.
struct MaskAppearancePreview: View {
    @ObservedObject var settings: MaskSettings
    private static let canvas = CGSize(width: 1152, height: 720)
    private static let sampleDate = Date(timeIntervalSince1970: 1_566_561_660)
    /// A made-up track with drawn artwork: the preview ships with the app, so no real song or cover.
    static let sampleTrack = MaskMediaTrack(.init(
        title: "Evening Drive", artist: "Sample Artist", isPlaying: true,
        durationMicros: 221_300_000, elapsedTimeMicros: 83_000_000, bundleIdentifier: "com.apple.Music",
        artwork: sampleArtwork
    ))!
    /// Read once; the sensor doesn't come and go while Settings is open.
    private static let hasTouchID = MaskTouchIDSession.isSensorPresent

    private static let sampleArtwork = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
        NSGradient(colors: [
            NSColor(red: 0.98, green: 0.55, blue: 0.62, alpha: 1),
            NSColor(red: 0.55, green: 0.42, blue: 0.95, alpha: 1),
            NSColor(red: 0.25, green: 0.70, blue: 0.95, alpha: 1),
        ])?.draw(in: rect, angle: -45)
        let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 84, weight: .medium))
        if let note {
            let tinted = NSImage(size: note.size, flipped: false) { noteRect in
                note.draw(in: noteRect)
                NSColor.white.withAlphaComponent(0.85).set()
                noteRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(
                x: rect.midX - note.size.width / 2, y: rect.midY - note.size.height / 2,
                width: note.size.width, height: note.size.height
            ))
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Preview"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                canvas
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    .scaleEffect(geometry.size.width / Self.canvas.width, anchor: .topLeading)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius).strokeBorder(.primary.opacity(0.1))
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Screen mask preview"))
            Text(L("Sample playback. Preview controls don't affect your player."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canvas: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if settings.showsMessage, let message = MaskMessage.displayed(settings.message) {
                    MaskMessageContent(message: message, onUnlock: {})
                } else {
                    keypad
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .trailing, spacing: 20) {
                HStack(spacing: 22) {
                    Text(Self.sampleDate, format: .dateTime.locale(settings.language.locale).month(.abbreviated).day().hour().minute())
                    HStack(spacing: 6) {
                        Image(systemName: "battery.100percent").font(.system(size: 17))
                        Text(verbatim: "100%")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                if settings.showsNowPlaying {
                    MaskNowPlayingCard(track: Self.sampleTrack, showsControls: settings.showsPlaybackControls,
                                       progressDate: Self.sampleDate, onCommand: { _ in })
                }
            }
            .padding(.top, 22)
            .padding(.trailing, 28)
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    private var keypad: some View {
        VStack(spacing: 28) {
            // Like the real keypad while Touch ID waits for a finger.
            Text(settings.touchIDUnlock && Self.hasTouchID ? L("Touch ID or Enter Passcode") : L("Enter Passcode"))
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 14) {
                ForEach(0..<6) { _ in
                    Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5).frame(width: 15, height: 15)
                }
            }
            VStack(spacing: 20) {
                ForEach(0..<4) { row in
                    HStack(spacing: 20) {
                        ForEach(0..<3) { column in
                            let value = row * 3 + column + 1
                            Group {
                                if value < 10 || value == 11 {
                                    Text(verbatim: value == 11 ? "0" : "\(value)")
                                        .font(.system(size: 30, weight: .light))
                                        .frame(width: 72, height: 72)
                                        .background(Circle().fill(.white.opacity(0.14)))
                                } else if value == 12 {
                                    Image(systemName: "delete.left").font(.system(size: 22)).frame(width: 72, height: 72)
                                } else {
                                    Color.clear.frame(width: 72, height: 72)
                                }
                            }
                        }
                    }
                }
            }
            Text(L("Forgot Passcode?"))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
    }
}
