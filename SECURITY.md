# Security Policy

MaskPad covers an unattended Mac and blocks its keyboard and mouse. What it protects against, and what
it deliberately doesn't, is described under [Security](README.md#security) in the README.

## Supported versions

Only the [latest release](https://github.com/gicek/MaskPad/releases/latest) gets fixes. MaskPad updates
itself through Sparkle, so a fix reaches installed copies with the next release.

## Reporting a vulnerability

Please report privately, not in a public issue:
[open a security advisory](https://github.com/gicek/MaskPad/security/advisories/new)
(the repository's **Security** tab > **Report a vulnerability**).

Include the MaskPad and macOS versions, what you did, and what happened. You can expect a first answer
within a week. Once a fix is released, the advisory is published and you are credited unless you ask not
to be.

## What counts

Worth a report:

- Removing or getting around the mask without the passcode, from the Mac's own keyboard, mouse, trackpad
  or touch screen, or from another process (the mask's buttons and digit keys are meant to accept only a
  person's input).
- Local input reaching the apps under the mask.
- Recovering the passcode, or skipping the wrong-passcode cooldown.
- A process without administrator rights using MaskPad to gain them (the command line tool installer and
  the Screen Sharing setting run a fixed command after the system's password prompt).
- Anything that makes an update install without a valid signature.

Known limits, documented in the README and not vulnerabilities:

- Input from macOS Screen Sharing and from tools that send events directly to apps is not blocked.
- Restarting the Mac, or killing MaskPad, removes the mask; the macOS login password is what protects the
  Mac then.
- "Unlock with Mac Password" lets anyone at the keyboard lock the Mac.
- Any app can turn the mask on.
- A 6-digit passcode can't resist someone who can read the Keychain item and try all codes offline.
