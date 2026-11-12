# Contributing to MaskPad

Bug reports, fixes and translations are welcome. For anything larger than a fix, please open an issue
first, so the idea can be discussed before you spend time on it.

A way around the mask is a security issue: report it privately, as described in
[SECURITY.md](SECURITY.md).

## Setting up

You need Xcode 27 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Python 3. See
[Building](README.md#building) in the README for the details.

```sh
brew install xcodegen
make run      # build the Debug app and launch it
make check    # string catalog check and unit tests; run before every commit
make open     # work in Xcode
```

Without a signing certificate the app is ad-hoc signed, and macOS asks for the Accessibility permission
again after every rebuild; [Signing](README.md#signing) explains how to avoid that.

## What a change needs

- **`make check` passes.** CI runs the same command on every pull request.
- **Tests for logic.** Decisions live in small types without system dependencies (`MaskTapPolicy`,
  `MaskUnlockState`, `SystemLockTracker`, …) so they can be tested; put new rules there, not in the
  controller or the views. Tests never touch real state: no Keychain, no real preferences, no global
  shortcut, no cursor or brightness changes.
- **Every string in every language.** User-facing text is an English literal in `L("…")`; add its
  translations to `Scripts/translations.py` and run `make strings`. `make check` fails on a missing or
  unused translation.
- **A hand test with the mask on**, for changes to the mask, input blocking, unlocking, dimming or lock
  detection: unit tests can't cover WindowServer and event-tap behavior. Say in the pull request what you
  tried (displays, Screen Sharing, sleep and wake).
- **README updated** when behavior or the build changes.

## Rules the design depends on

- Software can turn the mask on, never off. No shortcut, URL, command or API removes the mask.
- When unsure, keep the mask: wrongly keeping it costs one passcode entry, wrongly removing it is a
  bypass.
- Key input is never logged.
- Discuss new dependencies before adding them. Sparkle and MediaRemoteAdapter are the current dependencies,
  pinned in `project.yml`.
- Private frameworks are looked up at run time (`dlsym`), and every use has a fallback when the symbol is
  missing.

## Style

- Swift 6 language mode with complete concurrency checking; builds have no warnings. Prefer `@MainActor`
  types to `@unchecked Sendable`.
- Comments say why, not what, and document the constraint that led to the code.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org) (`fix(mask): …`,
  `feat(settings): …`, `docs: …`), in the imperative, describing the change for someone using the app.

By contributing you agree that your work is released under the project's [MIT license](LICENSE).
