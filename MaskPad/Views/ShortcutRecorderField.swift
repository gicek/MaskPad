import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shortcut recorder. Click to start recording, then press the key combination.
///
/// **Records real keystrokes instead of building chords from pickers**, which are either incomplete or
/// force users to guess key names like "equal". A local event monitor swallows keys while recording;
/// otherwise the settings window's own menu shortcuts would consume them first.
struct ShortcutRecorderField: View {
    let chord: KeyChord?
    /// Validates a recorded chord; a non-nil message rejects it and is shown by the caller.
    let validate: (KeyChord) -> String?
    let onChange: (KeyChord?) -> Void
    @Binding var errorText: String?

    @State private var isRecording = false
    @State private var monitor: Any?
    /// When a mouse click stopped recording. If the click was on the field itself, the following tap
    /// gesture must not restart recording; the click meant "cancel".
    @State private var stoppedByClickAt: Date?
    @State private var hotKeyRecordingToken: UUID?

    /// The clear button sits on the field's top-trailing corner rather than in its own column, which would
    /// wedge a delete icon between the chord and the next control.
    ///
    /// Field and button are sibling views in a `ZStack`, not a button nested in a button, which would make
    /// hit testing ambiguous. Recording uses a tap gesture, with button traits added for accessibility.
    var body: some View {
        ZStack(alignment: .topTrailing) {
            label
                .foregroundStyle(textColor)
                .frame(width: 128, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor, lineWidth: isRecording ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture(perform: toggleRecording)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(L("Record a key combination"))

            // Only when bound: an empty row shouldn't show a no-op clear button.
            if chord != nil {
                Button {
                    stopRecording()
                    errorText = nil
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
                        // The glyph is tiny; make the whole circle hittable.
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .help(L("Clear"))
                .accessibilityLabel(L("Clear"))
            }
        }
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    /// Lays out keys one by one. Not monospaced: SF Mono lacks ⌃⌥⇧⌘ and the fallback glyphs look smaller
    /// than letters, so use the system font with spacing between keys.
    @ViewBuilder
    private var label: some View {
        if isRecording {
            Text(L("Press keys")).font(.body)
        } else if let chord {
            HStack(spacing: 1) {
                ForEach(Array(chord.displayTokens.enumerated()), id: \.offset) { _, token in
                    Text(token)
                }
            }
            .font(.body.weight(.medium))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(chord.displayText)
        } else {
            Text(L("Not set")).font(.body)
        }
    }

    private var textColor: Color {
        if isRecording { return .accentColor }
        return chord == nil ? .secondary : .primary
    }

    private var borderColor: Color {
        isRecording ? .accentColor : Color(nsColor: .separatorColor)
    }

    private func toggleRecording() {
        if let stoppedByClickAt, Date().timeIntervalSince(stoppedByClickAt) < 0.5 {
            self.stoppedByClickAt = nil
            return
        }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        hotKeyRecordingToken = GlobalHotKeyCenter.shared.beginRecording()
        isRecording = true
        errorText = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            // A click elsewhere cancels recording; let the event through (the user is likely clicking another control).
            guard event.type == .keyDown else {
                stopRecording()
                stoppedByClickAt = Date()
                return event
            }
            handle(event)
            // Swallow: keys during recording belong to the recorder and must not trigger menu shortcuts.
            return nil
        }
        if monitor == nil { stopRecording() }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        if let token = hotKeyRecordingToken {
            hotKeyRecordingToken = nil
            GlobalHotKeyCenter.shared.endRecording(token)
        }
    }

    private func handle(_ event: NSEvent) {
        guard let recorded = KeyChord(event: event) else { return }

        // Bare Esc cancels and bare Delete clears, per common recorder conventions.
        // With modifiers they are ordinary recordable chords (e.g. ⌘⌫).
        if recorded.hasModifier == false {
            if recorded.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return
            }
            if recorded.keyCode == UInt16(kVK_Delete) {
                stopRecording()
                errorText = nil
                onChange(nil)
                return
            }
        }

        stopRecording()
        if let problem = validate(recorded) {
            errorText = problem
            return
        }
        errorText = nil
        onChange(recorded)
    }
}
