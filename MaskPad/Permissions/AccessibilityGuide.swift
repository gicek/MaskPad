// AccessibilityGuide.swift
// Accessibility permission guide.
// Flow: the settings banner button opens System Settings > Accessibility; a snapshot of the banner
// flies along an arc (crossfade at the apex, bell-curve blur, layered shadows) and docks inside the
// System Settings window as a drag strip; the user drags the MaskPad icon (a real NSDraggingSource)
// into the list; we poll for trust, then wrap up and return to settings.
//
// No AXIsProcessTrustedWithOptions prompt: it triggers two chained system dialogs, which the user
// must click through before reaching System Settings.

import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

@MainActor
final class AccessibilityGuide: NSObject, ObservableObject {
    static let shared = AccessibilityGuide()

    /// True while flying or docked; the settings banner then shows "Finish in System Settings".
    @Published private(set) var isActive = false

    private var guidePanel: NSPanel?
    private var replicant: FlightReplicantWindow?
    private var grantWatcher: Task<Void, Never>?
    private var guideFlow: Task<Void, Never>?
    private var settingsTracking: Task<Void, Never>?
    private let guideModel = AccessibilityGuideModel()

    /// Flight origin: the settings banner's screen rect and snapshot (rect is re-read for the return flight).
    private var sourceRect: () -> NSRect? = { nil }
    private var sourceSnapshot: NSImage?
    private var targetImage: NSImage?
    private var targetFrame: NSRect = .zero
    private var onGranted: () -> Void = {}
    /// Session number, incremented on finish. Async tasks compare it on wake and bail if stale,
    /// so a cancelled session can't tear down the next session's strip or polling.
    private var generation = 0

    private static var isGranted: Bool { MaskController.canBlockLocalInput }

    /// Starts the guide. `sourceRect` and `sourceSnapshot` give the banner's screen rect and image as the
    /// flight origin; `onGranted` is called once permission is granted.
    func start(
        sourceRect: @escaping () -> NSRect?,
        sourceSnapshot: NSImage?,
        onGranted: @escaping () -> Void
    ) {
        guard isActive == false else { return }
        // A return flight still in progress (banner already clickable): tear it down and start over.
        if guideFlow != nil { finish(granted: false) }
        if Self.isGranted {
            onGranted()
            return
        }
        self.sourceRect = sourceRect
        self.sourceSnapshot = sourceSnapshot
        self.onGranted = onGranted
        let generation = self.generation
        startGrantWatcher(generation)
        guideFlow = Task { [weak self] in
            await self?.runGuideFlow(generation)
            if self?.generation == generation { self?.guideFlow = nil }
        }
    }

    /// Dismisses the guide without granting (e.g. settings window closed).
    func cancel() {
        guard isActive || guideFlow != nil else { return }
        finish(granted: false)
    }

    // MARK: Flow: open System Settings → fly and dock → drag

    private func runGuideFlow(_ generation: Int) async {
        openSettingsPane()
        isActive = true
        let settingsFrame = await waitForSettingsWindow()
        guard generation == self.generation else { return }
        guard let settingsFrame, !Task.isCancelled else {
            finish(granted: false)
            return
        }

        // System Settings is now frontmost; bring MaskPad back so the flight origin is visible.
        NSApp.activate(ignoringOtherApps: true)

        guideModel.phase = .drag
        let guide = guidePanel ?? makeGuidePanel()
        guidePanel = guide
        guide.contentView = NSHostingView(rootView: AccessibilityGuideView(
            model: guideModel,
            isStaticRender: false,
            onBack: { [weak self] in self?.returnFromGuide() },
            onDraggableCreated: { [weak self] view in
                view.onDragEnded = { operation in
                    Task { @MainActor [weak self] in
                        guard operation != [] else { return }
                        self?.guideModel.phase = .toggle
                    }
                }
            }
        ))
        guide.setContentSize(AccessibilityGuideView.contentSize)

        targetFrame = dockedFrame(near: settingsFrame)
        targetImage = renderGuideSnapshot(scale: NSScreen.best(for: targetFrame)?.backingScaleFactor ?? 2)
        let start = sourceRect() ?? targetFrame

        await runFlight(from: start, to: targetFrame, reversed: false)
        guard generation == self.generation, !Task.isCancelled else { return }

        guide.setFrame(targetFrame, display: true)
        guide.orderFrontRegardless()
        replicant?.orderOut(nil)

        // Hand focus back to System Settings for dropping; the strip is a non-activating floating panel and stays visible.
        activateSystemSettings()
        startSettingsTracking(generation)
    }

    /// The strip's back button: fly back to the settings banner, which is restored as the flight passes the apex.
    private func returnFromGuide() {
        guard settingsTracking != nil || guidePanel?.isVisible == true else { return }
        settingsTracking?.cancel()
        settingsTracking = nil
        grantWatcher?.cancel()
        grantWatcher = nil
        guidePanel?.orderOut(nil)
        let generation = self.generation
        guideFlow = Task { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.shared.show()
            let end = self.sourceRect() ?? self.targetFrame
            await self.runFlight(from: end, to: self.targetFrame, reversed: true, deactivateAtApex: true)
            guard generation == self.generation else { return }
            self.finish(granted: false)
        }
    }

    // MARK: System Settings window detection and tracking

    private func openSettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Waits until the window appears and is stable (two matching samples) to avoid docking mid-animation.
    private func waitForSettingsWindow() async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(6)
        let stabilizationBudget: Duration = .milliseconds(1200)
        var firstSeenAt: ContinuousClock.Instant?
        var lastFrame: CGRect?

        while clock.now < deadline, !Task.isCancelled {
            if let frame = settingsWindowFrame() {
                if let lastFrame, frame.integral == lastFrame.integral { return frame }
                if firstSeenAt == nil {
                    firstSeenAt = clock.now
                } else if let firstSeenAt, clock.now - firstSeenAt >= stabilizationBudget {
                    return frame
                }
                lastFrame = frame
            } else {
                firstSeenAt = nil
                lastFrame = nil
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return lastFrame
    }

    /// System Settings main window frame in AppKit screen coordinates. Filters by PID because the owner
    /// name is localized. Reads only window bounds, so no Screen Recording permission is needed.
    /// With `onScreenOnly` false, minimized and other-Space windows count too (used only to check existence).
    private func settingsWindowFrame(onScreenOnly: Bool = true) -> CGRect? {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.excludeDesktopElements]
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier,
              let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]]
        else { return nil }

        // Pick the largest match so transient popovers don't win over the main window.
        var best: CGRect?
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 300, frame.height >= 200
            else { continue }
            if best == nil || frame.width * frame.height > best!.width * best!.height {
                best = frame
            }
        }
        guard let cgFrame = best, let primary = NSScreen.screens.first else { return nil }
        // CG global coordinates (top-left origin) to AppKit screen coordinates (bottom-left origin).
        return CGRect(
            x: cgFrame.minX,
            y: primary.frame.height - cgFrame.minY - cgFrame.height,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    /// Dock position: bottom-trailing inside the System Settings window with 16pt inset, clamped to the visible screen.
    private func dockedFrame(near settingsFrame: CGRect) -> NSRect {
        let size = AccessibilityGuideView.contentSize
        let visible = NSScreen.best(for: settingsFrame)?.visibleFrame ?? settingsFrame
        let inset: CGFloat = 16
        let x = min(max(settingsFrame.maxX - size.width - inset, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(settingsFrame.minY + inset, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Follows the System Settings window: moves with it, hides while it's minimized or on another Space,
    /// and ends the guide only when the window is gone, so the settings banner can be retried.
    private func startSettingsTracking(_ generation: Int) {
        settingsTracking?.cancel()
        settingsTracking = Task { [weak self] in
            var missCount = 0
            var lastFrame: CGRect?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                if let frame = self.settingsWindowFrame() {
                    missCount = 0
                    if frame != lastFrame {
                        lastFrame = frame
                        let docked = self.dockedFrame(near: frame)
                        self.targetFrame = docked
                        self.guidePanel?.setFrame(docked, display: true, animate: false)
                    }
                    if self.guidePanel?.isVisible == false { self.guidePanel?.orderFrontRegardless() }
                } else if self.settingsWindowFrame(onScreenOnly: false) != nil {
                    missCount = 0
                    lastFrame = nil
                    self.guidePanel?.orderOut(nil)
                } else {
                    missCount += 1
                    if missCount >= 4 {
                        self.finish(granted: false)
                        return
                    }
                }
            }
        }
    }

    private func activateSystemSettings() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?
            .activate(from: .current, options: [])
    }

    // MARK: Flight animation (arc, apex crossfade, bell-curve blur)
    // These constants define the effect: 0.78s forward / 0.6s back, 160pt arc height,
    // 12→22 corner radius, crossfade window 0.35–0.65, peak blur 12, shadow layers 2/15/3.

    private func runFlight(from sourceFrame: NSRect, to targetFrame: NSRect, reversed: Bool, deactivateAtApex: Bool = false) async {
        let replicant = self.replicant ?? FlightReplicantWindow()
        self.replicant = replicant
        replicant.model.sourceImage = sourceSnapshot
        replicant.model.targetImage = targetImage

        let sourceCornerRadius: CGFloat = 8
        let cardCornerRadius = AccessibilityGuideView.cardCornerRadius
        let duration: TimeInterval = reversed ? 0.6 : 0.78
        let maxBlur: CGFloat = 12
        let arcHeight: CGFloat = 160
        var deactivated = false

        replicant.apply(
            frame: reversed ? targetFrame : sourceFrame,
            cornerRadius: reversed ? cardCornerRadius : sourceCornerRadius,
            progress: reversed ? 1 : 0,
            shadowOpacity: reversed ? 1 : 0,
            blurRadius: 0
        )
        replicant.orderFrontRegardless()

        let startTime = CACurrentMediaTime()
        while !Task.isCancelled {
            let t = min(max((CACurrentMediaTime() - startTime) / duration, 0), 1)
            let eased = easeInOutCubic(t)
            let progress = reversed ? 1 - eased : eased

            // On the return flight, restore the banner at the apex; the swap is hidden behind the flying proxy.
            if deactivateAtApex, !deactivated, t >= 0.5 {
                deactivated = true
                isActive = false
            }

            let center = parabolicPoint(
                t: progress,
                start: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
                end: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                arcHeight: arcHeight
            )
            let width = sourceFrame.width + (targetFrame.width - sourceFrame.width) * progress
            let height = sourceFrame.height + (targetFrame.height - sourceFrame.height) * progress
            let crossfade = apexCrossfade(t)

            replicant.apply(
                frame: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                cornerRadius: sourceCornerRadius + (cardCornerRadius - sourceCornerRadius) * progress,
                progress: reversed ? 1 - crossfade : crossfade,
                shadowOpacity: progress,
                blurRadius: bellBlur(t) * maxBlur
            )
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func parabolicPoint(t: CGFloat, start: CGPoint, end: CGPoint, arcHeight: CGFloat) -> CGPoint {
        let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + arcHeight)
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    /// Bell-curve blur: zero at both ends, peak at the apex.
    private func bellBlur(_ t: CGFloat) -> CGFloat { 4 * t * (1 - t) }

    /// Smooth crossfade around the apex: source for the first 35%, transition over the middle 30%, target for the last 35%.
    private func apexCrossfade(_ t: CGFloat) -> CGFloat {
        if t < 0.35 { return 0 }
        if t > 0.65 { return 1 }
        let local = (t - 0.35) / 0.3
        return local * local * (3 - 2 * local)
    }

    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Static snapshot of the strip (the flight's target image). ImageRenderer can't render
    /// NSViewRepresentable, so the drag row uses a same-size pure SwiftUI stand-in.
    private func renderGuideSnapshot(scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: AccessibilityGuideView(
            model: guideModel, isStaticRender: true, onBack: {}, onDraggableCreated: { _ in }
        ))
        renderer.scale = scale
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(AccessibilityGuideView.contentSize)
        return renderer.nsImage
    }

    // MARK: Permission polling

    private func startGrantWatcher(_ generation: Int) {
        grantWatcher?.cancel()
        grantWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                if Self.isGranted {
                    self.finish(granted: true)
                    return
                }
            }
        }
    }

    private func finish(granted: Bool) {
        generation += 1
        grantWatcher?.cancel()
        grantWatcher = nil
        guideFlow?.cancel()
        guideFlow = nil
        settingsTracking?.cancel()
        settingsTracking = nil
        replicant?.orderOut(nil)
        guidePanel?.orderOut(nil)
        guidePanel?.contentView = nil
        sourceSnapshot = nil
        targetImage = nil
        isActive = false
        if granted {
            // Return to MaskPad settings; the banner disappears.
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.shared.show()
            onGranted()
        }
        onGranted = {}
        sourceRect = { nil }
    }

    private func makeGuidePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: AccessibilityGuideView.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

// MARK: - Drag strip

@MainActor
final class AccessibilityGuideModel: ObservableObject {
    enum Phase {
        case drag    // Prompt to drag into the list
        case toggle  // Added: prompt to turn on the switch
    }

    @Published var phase: Phase = .drag
}

struct AccessibilityGuideView: View {
    @ObservedObject var model: AccessibilityGuideModel
    let isStaticRender: Bool
    var onBack: () -> Void
    var onDraggableCreated: (DraggableAppIconNSView) -> Void

    static let contentSize = CGSize(width: 500, height: 130)
    static let cardCornerRadius: CGFloat = 22

    @State private var arrowScale: CGFloat
    @State private var arrowOffsetY: CGFloat
    @State private var arrowOpacity: CGFloat

    init(
        model: AccessibilityGuideModel,
        isStaticRender: Bool,
        onBack: @escaping () -> Void,
        onDraggableCreated: @escaping (DraggableAppIconNSView) -> Void
    ) {
        self.model = model
        self.isStaticRender = isStaticRender
        self.onBack = onBack
        self.onDraggableCreated = onDraggableCreated
        // Static snapshots use the final pose; live rendering springs in from the pre-entrance pose.
        _arrowScale = State(initialValue: isStaticRender ? 1.0 : 0.2)
        _arrowOffsetY = State(initialValue: isStaticRender ? 0 : 18)
        _arrowOpacity = State(initialValue: isStaticRender ? 1 : 0)
    }

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ProcessInfo.processInfo.processName
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.tint)
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 6, y: 2)
                        .frame(width: 28, height: 28)
                        .scaleEffect(arrowScale)
                        .offset(y: arrowOffsetY)
                        .opacity(arrowOpacity)
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .opacity(arrowOpacity)
                    Spacer(minLength: 0)
                }
                draggableRow
                    .frame(height: 44)
            }
            .padding(.vertical, 14)
            .padding(.leading, 52)
            .padding(.trailing, 18)
            .frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )

            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .padding(.top, (Self.contentSize.height - 32) / 2)
        }
        .onAppear(perform: playEntranceAnimation)
    }

    private var caption: String {
        switch model.phase {
        case .drag: L("Drag \(Self.appName) into the list above to allow Accessibility")
        case .toggle: L("Turn on \(Self.appName) in the list above")
        }
    }

    // ImageRenderer can't render NSViewRepresentable; snapshots use a matching pure SwiftUI stand-in.
    @ViewBuilder
    private var draggableRow: some View {
        let pill = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isStaticRender {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text(Self.appName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: pill)
            .overlay(pill.strokeBorder(.separator.opacity(0.6)))
        } else {
            DraggableAppIconRepresentable(onCreated: onDraggableCreated)
                .background(.quaternary.opacity(0.5), in: pill)
                .overlay(pill.strokeBorder(.separator.opacity(0.6)))
        }
    }

    private func playEntranceAnimation() {
        guard !isStaticRender else { return }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 200, damping: 11, initialVelocity: 18)) {
            arrowScale = 1.0
            arrowOffsetY = 0
            arrowOpacity = 1
        }
    }
}

// MARK: - Flight proxy window (crossfades banner snapshot into strip snapshot in flight)

@MainActor
final class FlightReplicantModel: ObservableObject {
    @Published var sourceImage: NSImage?
    @Published var targetImage: NSImage?
    @Published var progress: CGFloat = 0
    @Published var blurRadius: CGFloat = 0
    @Published var cornerRadius: CGFloat = 12
    @Published var shadowOpacity: CGFloat = 0
    @Published var contentSize: CGSize = .zero
}

struct FlightReplicantContentView: View {
    @ObservedObject var model: FlightReplicantModel

    var body: some View {
        ZStack {
            // Both snapshots stretch to fill the proxy rect so the banner size morphs smoothly into the strip size.
            if let source = model.sourceImage {
                Image(nsImage: source).resizable().interpolation(.high).opacity(1 - model.progress)
            }
            if let target = model.targetImage {
                Image(nsImage: target).resizable().interpolation(.high).opacity(model.progress)
            }
        }
        .frame(width: model.contentSize.width, height: model.contentSize.height)
        .clipShape(RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous))
        .compositingGroup()
        .blur(radius: model.blurRadius)
        .shadow(color: .black.opacity(0.18 * model.shadowOpacity), radius: 2)
        .shadow(color: .black.opacity(0.22 * model.shadowOpacity), radius: 15, y: -6)
        .shadow(color: .black.opacity(0.14 * model.shadowOpacity), radius: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class FlightReplicantWindow: NSPanel {
    /// Padding around the content so shadows and blur aren't clipped by the window edge.
    static let chromeInset: CGFloat = 40

    let model = FlightReplicantModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: FlightReplicantContentView(model: model))
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(frame contentFrame: NSRect, cornerRadius: CGFloat, progress: CGFloat, shadowOpacity: CGFloat, blurRadius: CGFloat) {
        let inset = Self.chromeInset
        setFrame(contentFrame.insetBy(dx: -inset, dy: -inset), display: false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.cornerRadius = cornerRadius
            model.progress = progress
            model.shadowOpacity = shadowOpacity
            model.blurRadius = blurRadius
            model.contentSize = contentFrame.size
        }
    }
}

// MARK: - Draggable app icon (real drag source; dropping into the System Settings list writes TCC)

@MainActor
final class DraggableAppIconNSView: NSView, NSDraggingSource {
    private let dragThreshold: CGFloat = 3
    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false

    private let iconView = NSImageView()
    private let nameLabel: NSTextField

    var onDragEnded: ((NSDragOperation) -> Void)?

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: AccessibilityGuideView.appName)
        super.init(frame: frameRect)

        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        icon.size = NSSize(width: 32, height: 32)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !hasStartedDrag else {
            super.mouseDragged(with: event)
            return
        }
        let distance = hypot(
            event.locationInWindow.x - down.locationInWindow.x,
            event.locationInWindow.y - down.locationInWindow.y
        )
        guard distance >= dragThreshold else { return }
        hasStartedDrag = true
        startDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        hasStartedDrag = false
        super.mouseUp(with: event)
    }

    private func startDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: rowSnapshot() ?? iconView.image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// Drag preview is a snapshot of the whole row (icon + app name), matching the strip.
    private func rowSnapshot() -> NSImage? {
        guard bounds.width > 1, bounds.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor in
            self.mouseDownEvent = nil
            self.hasStartedDrag = false
            self.onDragEnded?(operation)
        }
    }
}

struct DraggableAppIconRepresentable: NSViewRepresentable {
    let onCreated: (DraggableAppIconNSView) -> Void

    func makeNSView(context: Context) -> DraggableAppIconNSView {
        let view = DraggableAppIconNSView(frame: NSRect(x: 0, y: 0, width: 430, height: 44))
        DispatchQueue.main.async { onCreated(view) }
        return view
    }

    func updateNSView(_ nsView: DraggableAppIconNSView, context: Context) {}
}

// MARK: - Flight origin anchor

/// Transparent anchor view exposing the settings banner's position, for screen-rect conversion and snapshots.
@MainActor
final class GuideAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Renders this region from the anchor's window (no screen capture, so no Screen Recording permission).
    func snapshot() -> NSImage? {
        guard let view, let contentView = view.window?.contentView else { return nil }
        let rect = contentView.convert(view.bounds, from: view)
        guard rect.width > 1, rect.height > 1,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        contentView.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}

struct GuideAnchorReader: NSViewRepresentable {
    let anchor: GuideAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
