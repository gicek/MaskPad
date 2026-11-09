#!/bin/zsh
# Regenerates the app icon and menu bar icon in the asset catalog from design/logo.
# Requires Node (renders with resvg via `npx @resvg/resvg-js-cli`).
set -euo pipefail

root=${0:A:h:h}
logo=$root/design/logo
assets=$root/MaskPad/Resources/Assets.xcassets
appicon=$assets/AppIcon.appiconset
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# macOS icon grid: 824 x 824 rounded square centered on the 1024 canvas, with a drop shadow.
# The full-bleed background logo is scaled into that shape.
body=$(sed '1d;$d' "$logo/maskpad-logo-1024-background.svg")
cat > "$tmp/appicon.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <clipPath id="appIconShape"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
    <filter id="appIconShadow" x="-10%" y="-10%" width="120%" height="130%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <g filter="url(#appIconShadow)">
    <g clip-path="url(#appIconShape)">
      <g transform="translate(100 100) scale(0.8046875)">
$body
      </g>
    </g>
  </g>
</svg>
SVG

render() { npx -y @resvg/resvg-js-cli --fit-width "$2" "$1" "$3" >/dev/null; }

for size in 16 32 128 256 512; do
  render "$tmp/appicon.svg" $size "$appicon/icon_${size}x${size}.png"
  render "$tmp/appicon.svg" $((size * 2)) "$appicon/icon_${size}x${size}@2x.png"
done

cp "$logo/maskpad-logo-1024-menubar.svg" "$assets/MenuBarIcon.imageset/MenuBarIcon.svg"
echo "Icons written to $assets"
