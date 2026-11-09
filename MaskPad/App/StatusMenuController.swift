import AppKit
import Combine

/// Status bar item and menu: Turn On Screen Mask / Settings… / Quit.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let engageItem = NSMenuItem()
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

        let settingsItem = NSMenuItem(title: L("Settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quitItem = NSMenuItem(title: L("Quit MaskPad"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.items = [engageItem, .separator(), settingsItem, .separator(), quitItem]
        // Text-only menu. macOS 27 adds a system symbol to standard items such as Settings on its own;
        // hide images on every item so the menu stays consistent.
        if #available(macOS 27, *) {
            for item in menu.items where item.isSeparatorItem == false {
                item.preferredImageVisibility = .hidden
            }
        }
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
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// Shows the global hotkey on the menu item as a reminder; the hotkey doesn't rely on keyEquivalent.
    /// Hidden if registration failed (taken by another app), so the menu never shows a dead shortcut.
    private func refresh() {
        engageItem.title = L("Turn On Screen Mask")
        engageItem.isEnabled = MaskController.shared.isEngaged == false
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
