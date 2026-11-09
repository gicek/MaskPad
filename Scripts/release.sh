#!/bin/zsh
# Builds a Developer ID–signed, notarized MaskPad-<version>.zip in build/Release.
#
#   Scripts/release.sh                   # archive, export, notarize, staple, zip
#   Scripts/release.sh --skip-notarize   # archive, export, zip (not notarized)
#
# Requires Developer ID signing in Config/MaskPad.local.xcconfig and, for notarization, a notarytool
# keychain profile (default name "MaskPad", override with NOTARY_PROFILE):
#   xcrun notarytool store-credentials MaskPad --apple-id <apple-id> --team-id <team-id>
set -euo pipefail

root=${0:A:h:h}
cd "$root"
notarize=true
[[ "${1:-}" == "--skip-notarize" ]] && notarize=false
profile=${NOTARY_PROFILE:-MaskPad}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

out=$root/build/Release
archive=$out/MaskPad.xcarchive
export_dir=$out/export
app=$export_dir/MaskPad.app
rm -rf "$out"
mkdir -p "$out"

xcodegen generate --quiet

setting() {
  xcodebuild -project MaskPad.xcodeproj -scheme MaskPad -configuration Release -showBuildSettings 2>/dev/null \
    | awk -v key="$1" '$1 == key { print $3; exit }'
}
version=$(setting MARKETING_VERSION)
team=$(setting DEVELOPMENT_TEAM)
if [[ -z "$team" ]]; then
  echo "Developer ID signing is not configured; see Config/MaskPad.local.xcconfig.example." >&2
  exit 1
fi

echo "==> Archiving MaskPad $version"
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

zip=$out/MaskPad-$version.zip
if $notarize; then
  echo "==> Notarizing (profile: $profile)"
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait
  xcrun stapler staple "$app"
  spctl -a -t exec -vv "$app"
  rm "$out/notarize.zip"
fi

ditto -c -k --keepParent "$app" "$zip"
echo "==> $zip"
$notarize || echo "    (not notarized)"
