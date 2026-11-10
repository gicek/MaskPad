# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow==13.0.0"]
# ///
"""Writes design/dmg/volume.icns, the icon of the mounted MaskPad volume, and volume.png, the same image
at 1024 px for review. Run by Scripts/build_icons.sh (`uv run --script` installs Pillow); the output is
committed, so building and releasing never need Pillow.

Takes this Mac's removable disk icon (what a mounted DMG shows by default), erases its download arrow and
puts the MaskPad logo in its place.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
LOGO = ROOT / "design/logo/maskpad-logo-1024-transparent.png"
OUT = ROOT / "design/dmg"
# Same path on macOS 14 and later.
SYSTEM_DISK_ICON = Path("/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/Removable.icns")


def render_icns(icns: Path, size: int) -> Image.Image:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "icon.png"
        subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size), str(icns), "--out", str(out)],
                       check=True, capture_output=True)
        return Image.open(out).convert("RGBA")


def main() -> None:
    if not SYSTEM_DISK_ICON.is_file():
        sys.exit(f"System disk icon not found: {SYSTEM_DISK_ICON}")
    disk = render_icns(SYSTEM_DISK_ICON, 1024)

    # Erase the download arrow: fill each row of its box by interpolating the clean pixels on either side
    # (the disk face has only a faint horizontal gradient).
    x0, x1, y0, y1 = 330, 694, 262, 660
    px = disk.load()
    for y in range(y0, y1):
        left, right = px[x0, y], px[x1, y]
        for x in range(x0 + 1, x1):
            t = (x - x0) / (x1 - x0)
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(left, right))

    # The logo is wider than tall, so fit it by width and center it on the disk face.
    logo = Image.open(LOGO).convert("RGBA")
    logo = logo.crop(logo.getbbox())
    target_w = 540
    logo = logo.resize((target_w, round(logo.height * target_w / logo.width)), Image.LANCZOS)
    pos = ((1024 - logo.width) // 2, 452 - logo.height // 2)

    shadow_alpha = Image.new("L", disk.size, 0)
    shadow_alpha.paste(logo.getchannel("A"), pos)
    shadow = Image.new("RGBA", disk.size, (0, 0, 0, 0))
    shadow.putalpha(ImageChops.multiply(shadow_alpha.filter(ImageFilter.GaussianBlur(14)), Image.new("L", disk.size, 70)))
    disk.alpha_composite(shadow.transform(disk.size, Image.AFFINE, (1, 0, 0, 0, 1, -10)))
    disk.alpha_composite(logo, pos)

    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "volume.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            disk.resize((base, base), Image.LANCZOS).save(iconset / f"icon_{base}x{base}.png")
            disk.resize((base * 2, base * 2), Image.LANCZOS).save(iconset / f"icon_{base}x{base}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "volume.icns")], check=True)
    disk.save(OUT / "volume.png")


if __name__ == "__main__":
    main()
