# dmgbuild settings for the MaskPad DMG (used by Scripts/release.sh; not run on its own).
# dmgbuild writes the volume's .DS_Store directly instead of scripting Finder, so it needs no automation
# permission and gives the same layout every time.
# Window size and icon positions must match design/dmg/background.svg, or the icons drift off the art.
# ruff: noqa: F821  # `defines` is injected by dmgbuild

import os.path

app = defines["app"]  # path to MaskPad.app
art = defines["art"]  # design/dmg (rendered by Scripts/build_icons.sh)
app_name = os.path.basename(app)

format = "UDZO"  # zlib; opens on every supported macOS version
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

icon = os.path.join(art, "volume.icns")
# dmgbuild picks up background@2x.png from the same folder and combines both into a multi-resolution TIFF.
background = os.path.join(art, "background.png")

# The window rect includes the title bar (about 32 pt with the toolbar hidden); the content area below it
# shows the 700 x 400 pt background.
window_rect = ((200, 160), (700, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (150, 196),
    "Applications": (550, 196),
}
hide_extensions = [app_name]
