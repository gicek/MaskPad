# MaskPad

MaskPad is a macOS menu bar app that covers your screens and blocks the keyboard and mouse without
locking the Mac. Everything underneath keeps running — downloads, builds, remote sessions and AI agents
that operate your apps — while anyone walking by can neither see nor use the Mac. Unlock it with a
6-digit passcode.

![MaskPad lock screen](docs/images/lock-screen.png)

## Features

- **Covers every display**, including full-screen apps, the menu bar, the Dock and notifications.
- **Blocks local input**: keyboard shortcuts, app switching, Force Quit, right-click, scrolling and
  gestures all stop working. Only the mouse pointer and clicks on the keypad get through.
- **Unlocks with a 6-digit passcode**, typed on the on-screen keypad or on the keyboard. Five wrong
  attempts trigger a 30-second cooldown.
- **Shows the date, time and battery level** in the top-right corner of the mask, formatted for the
  app's language. The battery turns red below 20 % when not plugged in.
- **Keeps your work running**: apps under the mask keep rendering, and tools that operate individual
  windows (such as Computer Use agents) keep working. The Mac doesn't sleep or lock on its own while
  masked.
- **Works with remote access**: through macOS Screen Sharing you see the keypad and can unlock
  remotely.
- **Forgot your passcode?** "Unlock with Mac Password" locks the Mac; after you log in with your Mac
  password the mask is gone and you can set a new passcode.
- **Optional**: turn on automatically after a period of inactivity, dim the screens after 20 seconds,
  launch at login, and a global shortcut (⌃⌘L by default).
- Available in English, 简体中文, 繁體中文, 日本語, Español, 한국어, Français and Deutsch.

## Getting Started

1. Build and launch MaskPad (see [Building](#building)). Its icon appears in the menu bar.
2. In **Settings**, click **Open System Settings** in the Accessibility banner and drag MaskPad into
   the list. MaskPad needs this permission to block the keyboard and mouse.
3. Set a 6-digit passcode.
4. Choose **Turn On Screen Mask** from the menu bar icon, or press ⌃⌘L.

Opening MaskPad again while it is running shows Settings.

## Security

MaskPad protects an unattended Mac from someone sitting down at it. It is not a replacement for the
macOS login password or FileVault.

- **Remote input is not blocked.** Input from macOS Screen Sharing and from tools that send events
  directly to apps bypasses the mask by design, so anyone with remote access to the Mac can still use
  it.
- **The passcode is 6 digits.** It is stored in the Keychain as a salted SHA-256 hash.
- **Restarting removes the mask.** Holding the power button or a crash ends MaskPad, and the Mac then
  falls back to its login password.
- **Locking the Mac removes the mask.** Anyone at the keyboard can use "Unlock with Mac Password" to
  lock the Mac, which interrupts whatever was running; getting back in still requires the Mac password.
  Closing the lid only removes the mask when macOS actually asks for the password on wake.
- **Private frameworks.** MaskPad uses SkyLight, DisplayServices and login.framework, which future
  macOS versions may change.

## How It Works

- **Mask windows** sit at the shielding window level on every display and Space. They use a 99 %
  opaque black background with `isOpaque = false`: fully opaque windows make WindowServer treat the
  apps beneath as occluded, and Chromium-based apps stop rendering.
- **Input blocking** is an HID-level `CGEventTap`. The pass/swallow rules live in `MaskTapPolicy`:
  pointer moves and left clicks pass, digits and Delete feed the keypad and are swallowed, everything
  else is swallowed. The key that triggered the shortcut gets its physical key-up through once, because
  macOS tracks key state per event source and would otherwise treat the next press as a repeat.
- **Kiosk mode** uses `NSApplication.presentationOptions` to hide the Dock and menu bar and disable
  app switching, Force Quit and logging out. A `PreventUserIdleDisplaySleep` assertion keeps the Mac
  awake.
- **Real lock detection** (`SystemLockTracker`): closing the lid locks the session immediately, but
  within the "require password after N minutes" grace period macOS unlocks again without a password.
  The mask is removed only after MaskPad's own lock request, a sleep longer than the password delay,
  or a lock that persists for 3 seconds.
- **Dimming** lowers brightness through DisplayServices and covers screens with a black overlay.
  Original brightness is saved before dimming and restored on wake or on the next launch.
- **The status bar** formats the date and time with the app's localization language and the system
  region's conventions (12/24-hour clock), and reads the internal battery from IOKit power sources.
  Macs without a battery show only the date and time.
- **The global shortcut** uses Carbon `RegisterEventHotKey`, which needs no extra permission.
- **Auto-engage** polls the HID idle time. Unlocking the mask and an active Screen Sharing session
  count as activity, since remote input doesn't reset the HID idle time.

## Building

Requirements: Xcode 27 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Python 3 for
the string catalog. MaskPad runs on macOS 14 or later.

```sh
brew install xcodegen
xcodegen generate
open MaskPad.xcodeproj
```

Or build and run the tests from the command line:

```sh
xcodebuild -project MaskPad.xcodeproj -scheme MaskPad -derivedDataPath build/DerivedData test
```

The `.xcodeproj` is generated from `project.yml` and is not committed.

### Signing

Without local configuration the app is ad-hoc signed. macOS then ties the Accessibility permission to
each build, so every rebuild has to be granted again. To avoid that, copy
`Config/MaskPad.local.xcconfig.example` to `Config/MaskPad.local.xcconfig` (ignored by Git) and set your
team and certificate. The test target uses the same signing, because the hardened-runtime app only
loads test code signed by the same team.

MaskPad is not sandboxed and uses private frameworks, so it is distributed with Developer ID rather
than through the Mac App Store.

### Release

```sh
Scripts/release.sh                   # archive, export with Developer ID, notarize, staple, zip
Scripts/release.sh --skip-notarize   # same without notarization
```

The result is `build/Release/MaskPad-<version>.zip`, a universal (Apple silicon and Intel) app.
Notarization uses a `notarytool` keychain profile: the `NOTARY_PROFILE` environment variable, else
`NOTARY_PROFILE` in `Config/MaskPad.local.xcconfig`, else `MaskPad`:

```sh
xcrun notarytool store-credentials MaskPad --apple-id <apple-id> --team-id <team-id>
```

### Tests

Unit tests cover the passcode, keypad, input-tap rules, lock detection, brightness recovery, idle
detection and shortcuts. Tests never touch real state: the passcode store is in memory, settings use a
separate defaults domain, and no global shortcut or menu bar item is created.

## Localization

Strings live in `Scripts/translations.py` and are compiled into the string catalog:

```sh
python3 Scripts/build_strings.py           # regenerate the catalog
python3 Scripts/build_strings.py --check   # validate only
```

The script fails when a string in the code has no translation, a translation is unused, placeholders
don't match, or an interpolated value's type isn't registered in `INT_VARS` / `STRING_VARS`.

## Icons

The source artwork is in `design/logo`. Regenerate the app icon and menu bar icon with:

```sh
Scripts/build_icons.sh   # requires Node
```

## Logging

```sh
/usr/bin/log show --predicate 'subsystem == "com.gicek.maskpad"'
```

MaskPad logs when the mask turns on or off, when a real system lock is detected, and when the shortcut
can't be registered. It never logs key input. Use `/usr/bin/log`, because zsh has a built-in `log`
command.

## Project Layout

```
MaskPad/App          app entry, menu bar menu, settings model, logging
MaskPad/Mask         mask windows, input blocking, keypad, passcode, lock detection, dimming
MaskPad/HotKeys      global shortcut
MaskPad/Permissions  Accessibility onboarding
MaskPad/Views        settings window
MaskPad/Resources    asset catalog and string catalog
Tests                unit tests
Scripts              string catalog and icon generators
design/logo          source artwork
docs/images          README images
```

## License

MIT. See [LICENSE](LICENSE).
