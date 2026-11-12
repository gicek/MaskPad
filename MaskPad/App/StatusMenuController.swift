import AppKit
import Combine

/// Status bar item and menu: Turn On Screen Mask / Settings / Check for Updates / Quit.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let engageItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            image?.accessibilityDescription = "MaskPad"
            button.image = image
            button.toolTip = "MaskPad"
        }

        engageItem.target = self
        engageItem.action = #selector(engage)

        settingsItem.action = #selector(openSettings)
        settingsItem.keyEquivalent = ","
        settingsItem.target = self
        updateItem.target = self
        updateItem.action = #selector(checkForUpdates)
        quitItem.action = #selector(quit)
        quitItem.keyEquivalent = "q"
        quitItem.target = self

        menu.items = [engageItem, .separator(), settingsItem, updateItem, .separator(), quitItem]
        // Text-only menu. macOS 27 adds a system symbol to standard items such as Settings on its own;
        // hide images on every item so the menu stays consistent.
        if #available(macOS 27, *) {
            for item in menu.items where item.isSeparatorItem == false {
                item.preferredImageVisibility = .hidden
            }
        }
        // `refresh()` sets `isEnabled` itself; with automatic enabling AppKit would turn every item with a
        // valid target back on whenever the menu opens.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        refresh()

        HotKeyBindingStore.shared.$bindings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        GlobalHotKeyCenter.shared.$unavailableActions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        AppUpdater.shared.$hasPendingUpdate
            .merge(with: AppUpdater.shared.$canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// Shows the global hotkey on the menu item as a reminder; the hotkey doesn't rely on keyEquivalent.
    /// Hidden if registration failed (taken by another app), so the menu never shows a dead shortcut.
    private func refresh() {
        settingsItem.title = L("Settings")
        quitItem.title = L("Quit MaskPad")
        engageItem.title = L("Turn On Screen Mask")
        engageItem.isEnabled = MaskController.shared.isEngaged == false
        // A found update stays clickable even while Sparkle's session is open: clicking brings its alert forward.
        let updater = AppUpdater.shared
        updateItem.title = updater.hasPendingUpdate ? L("Update Available") : L("Check for Updates")
        updateItem.isEnabled = updater.hasPendingUpdate || updater.canCheckForUpdates
        if GlobalHotKeyCenter.shared.unavailableActions.contains(.engageMask) == false,
           let chord = HotKeyBindingStore.shared.chord(for: .engageMask),
           let key = KeyChordSymbol.menuKeyEquivalent(for: chord.keyCode) {
            engageItem.keyEquivalent = key
            engageItem.keyEquivalentModifierMask = chord.modifiers.eventModifierFlags
        } else {
            engageItem.keyEquivalent = ""
            engageItem.keyEquivalentModifierMask = []
        }
    }

    @objc private func engage() {
        // Wait for the menu to close; otherwise its tracking loop fights the mask for key window.
        DispatchQueue.main.async { MaskActions.engageFromUser() }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
