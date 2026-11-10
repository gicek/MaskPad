#!/bin/zsh
# Builds a Developer ID–signed, notarized MaskPad-<version>.dmg (for downloads), MaskPad-<version>.zip
# (for Sparkle) and its appcast.xml in build/Release.
#
#   Scripts/release.sh                   # archive, export, DMG, notarize, staple, zip, appcast
#   Scripts/release.sh --publish         # same, then create GitHub release v<version> with DMG + zip + appcast
#   Scripts/release.sh --skip-notarize   # archive, export, DMG, zip (not notarized, no appcast)
#
# Requires Developer ID signing in Config/MaskPad.local.xcconfig and, for notarization, a notarytool
# keychain profile: NOTARY_PROFILE from the environment, else NOTARY_PROFILE in
# Config/MaskPad.local.xcconfig, else "MaskPad":
#   xcrun notarytool store-credentials MaskPad --apple-id <apple-id> --team-id <team-id>
# The appcast is signed with the Sparkle EdDSA key in the login Keychain (Sparkle's generate_keys).
# Release notes, if present, come from docs/release-notes/<version>.md.
# The DMG is built with dmgbuild (run through uv's uvx, pinned below) from Scripts/dmg_settings.py and the
# art in design/dmg (rendered by Scripts/build_icons.sh).
set -euo pipefail

root=${0:A:h:h}
cd "$root"
notarize=true
publish=false
for arg in "$@"; do
  case $arg in
    --skip-notarize) notarize=false ;;
    --publish) publish=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if $publish && ! $notarize; then
  echo "--publish requires notarization." >&2
  exit 2
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

repo=gicek/MaskPad
feed_url=https://github.com/$repo/releases/latest/download/appcast.xml
out=$root/build/Release
archive=$out/MaskPad.xcarchive
export_dir=$out/export
app=$export_dir/MaskPad.app
sparkle_bin=$out/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
dmg_art=$root/design/dmg
dmgbuild=(uvx --quiet --from dmgbuild==1.6.7 --with ds_store==1.3.3 --with mac_alias==2.2.3 dmgbuild)

# Check the DMG tooling before the slow build.
command -v uvx >/dev/null || { echo "uv is required to build the DMG: brew install uv" >&2; exit 1; }
for f in background.png background@2x.png volume.icns; do
  [[ -f "$dmg_art/$f" ]] || { echo "design/dmg/$f is missing; run Scripts/build_icons.sh." >&2; exit 1; }
done
"${dmgbuild[@]}" --help >/dev/null

xcodegen generate --quiet

setting() {
  xcodebuild -project MaskPad.xcodeproj -scheme MaskPad -configuration Release -showBuildSettings 2>/dev/null \
    | awk -v key="$1" '$1 == key { print $3; exit }'
}
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
team=$(setting DEVELOPMENT_TEAM)
profile=${NOTARY_PROFILE:-$(setting NOTARY_PROFILE)}
profile=${profile:-MaskPad}
tag=v$version
if [[ -z "$team" ]]; then
  echo "Developer ID signing is not configured; see Config/MaskPad.local.xcconfig.example." >&2
  exit 1
fi

# Sparkle compares CFBundleVersion, so every release needs a higher build number than the live feed.
# Check before the slow build, and before publishing, that the tree is clean and pushed.
if $publish; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working tree has uncommitted changes; commit them before publishing." >&2
    exit 1
  fi
  git fetch --quiet origin
  if [[ -z "$(git branch -r --contains HEAD)" ]]; then
    echo "HEAD is not on origin; push it before publishing." >&2
    exit 1
  fi
  if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
    echo "GitHub release $tag already exists; bump MARKETING_VERSION." >&2
    exit 1
  fi
fi
if $notarize && live=$(curl -fsL "$feed_url" 2>/dev/null); then
  live_build=$(grep -o '<sparkle:version>[^<]*' <<< "$live" | head -1 | sed 's/.*>//')
  if [[ -n "$live_build" ]] && (( build <= live_build )); then
    echo "CURRENT_PROJECT_VERSION ($build) must be greater than the published build ($live_build)." >&2
    exit 1
  fi
fi

rm -rf "$out"
mkdir -p "$out"

echo "==> Archiving MaskPad $version ($build)"
xcodebuild archive -project MaskPad.xcodeproj -scheme MaskPad -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$archive" -derivedDataPath "$out/DerivedData" -quiet

echo "==> Exporting with Developer ID"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$team</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$out/ExportOptions.plist" -quiet

echo "==> Checking the signature"
codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
grep -q "flags=.*runtime" <<< "$details" || { echo "Hardened runtime is missing." >&2; exit 1; }
grep -q "^Timestamp=" <<< "$details" || { echo "Secure timestamp is missing." >&2; exit 1; }
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then
  echo "The get-task-allow entitlement must not ship." >&2
  exit 1
fi
# Sparkle's helpers are re-signed on export; each must carry our team ID or Sparkle refuses to install.
# (Capture first: with pipefail, `codesign | grep -q` fails when grep exits early and codesign gets SIGPIPE.)
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
for helper in "$sparkle/Autoupdate" "$sparkle/Updater.app" "$sparkle"/XPCServices/*.xpc(N); do
  helper_details=$(codesign -dvv "$helper" 2>&1)
  grep -q "^TeamIdentifier=$team$" <<< "$helper_details" \
    || { echo "$helper is not signed by team $team." >&2; exit 1; }
done

echo "==> Packaging the DMG"
dmg=$out/MaskPad-$version.dmg
identity=$(sed -n 's/^Authority=//p' <<< "$details" | head -1)
"${dmgbuild[@]}" -s "$root/Scripts/dmg_settings.py" -D app="$app" -D art="$dmg_art" MaskPad "$dmg" >/dev/null
codesign --sign "$identity" --timestamp "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify -quiet "$dmg"

zip=$out/MaskPad-$version.zip
if $notarize; then
  # One submission covers both: notarizing the DMG also records the app inside it, so the exported app
  # (the same bits) can be stapled too before it is zipped for Sparkle.
  echo "==> Notarizing (profile: $profile)"
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler staple "$app"
  spctl -a -t open --context context:primary-signature -vv "$dmg"
  spctl -a -t exec -vv "$app"
fi

ditto -c -k --keepParent "$app" "$zip"
echo "==> $dmg"
echo "==> $zip"
if ! $notarize; then
  echo "    (not notarized, no appcast)"
  exit 0
fi

echo "==> Generating the appcast"
# Each release's appcast lists only that release; the feed URL always resolves to the latest one.
staging=$out/appcast
mkdir -p "$staging"
cp "$zip" "$staging/"
notes=$root/docs/release-notes/$version.md
[[ -f "$notes" ]] && cp "$notes" "$staging/MaskPad-$version.md"
"$sparkle_bin/generate_appcast" --embed-release-notes --maximum-versions 1 \
  --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
  --link "https://github.com/$repo" -o "$out/appcast.xml" "$staging"
grep -q 'sparkle:edSignature=' "$out/appcast.xml" || { echo "The appcast is not EdDSA-signed." >&2; exit 1; }
echo "==> $out/appcast.xml"

if $publish; then
  echo "==> Publishing GitHub release $tag"
  notes_args=(--notes "")
  [[ -f "$notes" ]] && notes_args=(--notes-file "$notes")
  gh release create "$tag" "$dmg" "$zip" "$out/appcast.xml" -R "$repo" --target "$(git rev-parse HEAD)" \
    --title "MaskPad $version" "${notes_args[@]}"
else
  echo "    Publish with: Scripts/release.sh --publish"
  echo "    (or upload MaskPad-$version.dmg, MaskPad-$version.zip and appcast.xml to a GitHub release tagged $tag)"
fi
