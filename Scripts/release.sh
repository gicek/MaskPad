#!/bin/zsh
# Builds MaskPad for distribution. Run it through make, which runs make check first:
#
#   make release   # Scripts/release.sh release: Developer ID–signed app and zip, not notarized
#                  #   -> build/release/MaskPad.app, MaskPad-<version>-unnotarized.zip
#   make dist      # Scripts/release.sh dist: the above, then a notarized DMG and zip and the appcast
#                  #   -> build/dist/MaskPad-<version>.dmg, MaskPad-<version>.zip, appcast.xml
#   make publish   # Scripts/release.sh publish: dist, then a draft GitHub release v<version> from build/dist;
#                  #   it is not live until make go-live (Scripts/github_release.sh)
#
# build/release and build/dist each get BUILD_INFO (version, commit, Xcode, signing and notarization) and
# SHA256SUMS, so either folder says which build it holds even when the other is from a different run.
# Intermediates (archive, export, DerivedData) go to build/intermediates and are rebuilt every run.
#
# Needs, and checks before building:
# - Xcode and XcodeGen
# - a Developer ID Application certificate for the team in Config/MaskPad.local.xcconfig
# - dist: uv (runs dmgbuild, pinned below, for the DMG layout in Scripts/dmg_settings.py) and the DMG art
#   in design/dmg (make icons)
# - dist: a notarytool keychain profile, from NOTARY_PROFILE in the environment, else in
#   Config/MaskPad.local.xcconfig, else "MaskPad":
#     xcrun notarytool store-credentials MaskPad --apple-id <apple-id> --team-id <team-id>
# - dist: the Sparkle EdDSA private key in the login Keychain, matching SUPublicEDKey, and a build number
#   higher than the live feed's
# - publish: gh, logged in; a clean, pushed tree; a version without a GitHub release; release notes
# Release notes come from docs/release-notes/<version>: en.md and <lang>.md for each of the app's
# languages (make bump creates them from a template). The appcast carries all of them and
# Sparkle shows the one in the app's language (Scripts/localize_appcast.py); the GitHub release shows the
# English notes. dist warns when any are missing or unedited, publish refuses.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
mode=${1:-}
case $mode in
  release) notarize=false; publish=false ;;
  dist) notarize=true; publish=false ;;
  publish) notarize=true; publish=true ;;
  *) echo "usage: Scripts/release.sh release|dist|publish" >&2; exit 2 ;;
esac

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }
need() { command -v "$1" >/dev/null || fail "$1 is missing; $2"; }

# Same default as the Makefile: Xcode, even when xcode-select points at the Command Line Tools.
if [[ -z ${DEVELOPER_DIR:-} ]]; then
  DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
  [[ -z $DEVELOPER_DIR || $DEVELOPER_DIR == *CommandLineTools* ]] && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR
[[ -x $DEVELOPER_DIR/usr/bin/xcodebuild ]] || fail "Xcode not found at $DEVELOPER_DIR; install it or set DEVELOPER_DIR."

repo=gicek/MaskPad
feed_url=https://github.com/$repo/releases/latest/download/appcast.xml
release_dir=$root/build/release
dist_dir=$root/build/dist
work=$root/build/intermediates
packages=$root/build/SourcePackages  # shared with make build, so packages are fetched once
archive=$work/MaskPad.xcarchive
export_dir=$work/export
sparkle_bin=$packages/artifacts/sparkle/Sparkle/bin
dmg_art=$root/design/dmg
dmgbuild=(uvx --quiet --from dmgbuild==1.6.7 --with ds_store==1.3.3 --with mac_alias==2.2.3 dmgbuild)
xcodebuild=(xcodebuild -project MaskPad.xcodeproj -scheme MaskPad -configuration Release
  -clonedSourcePackagesDirPath "$packages")

# --- Preflight: everything that can fail is checked before the slow build. ---

step "Checking prerequisites"
need xcodegen "brew install xcodegen"
xcodegen generate --quiet
settings=$("${xcodebuild[@]}" -showBuildSettings 2>/dev/null)
setting() { awk -v key="$1" '$1 == key { print $3; exit }' <<< "$settings"; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
team=$(setting DEVELOPMENT_TEAM)
profile=${NOTARY_PROFILE:-$(setting NOTARY_PROFILE)}
profile=${profile:-MaskPad}
tag=v$version
[[ -n $version && -n $build ]] || fail "Could not read the version from the build settings."
[[ -n $team ]] || fail "Developer ID signing is not configured; see Config/MaskPad.local.xcconfig.example."

# Release notes in every language: present, edited (no TODO line from the template) and not empty.
notes=$root/docs/release-notes/$version/en.md
missing_notes=$(PYTHONDONTWRITEBYTECODE=1 python3 Scripts/localize_appcast.py --missing "$version")
if [[ -n $missing_notes ]]; then
  problem="Release notes for $version are missing, empty or unedited in: $missing_notes (docs/release-notes/$version; make bump creates them)."
  $publish && fail "$problem"
  $notarize && echo "warning: $problem The appcast leaves those languages out." >&2
fi
english_notes=true
[[ " $missing_notes " == *" en "* ]] && english_notes=false
identities=$(security find-identity -v -p codesigning)
[[ $identities == *"Developer ID Application: "*"($team)"* ]] \
  || fail "No Developer ID Application certificate for team $team in the keychain."

if $notarize; then
  need uvx "brew install uv"
  for f in background.png background@2x.png volume.icns; do
    [[ -f $dmg_art/$f ]] || fail "design/dmg/$f is missing; run make icons."
  done
  "${dmgbuild[@]}" --help >/dev/null || fail "dmgbuild could not be installed through uv."

  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "notarytool profile \"$profile\" is missing or invalid:
  xcrun notarytool store-credentials $profile --apple-id <apple-id> --team-id $team"

  # The appcast must be signed with the private half of SUPublicEDKey, or installed copies reject updates.
  "${xcodebuild[@]}" -resolvePackageDependencies -quiet
  expected=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' MaskPad/Info.plist)
  actual=$("$sparkle_bin/generate_keys" -p 2>/dev/null) \
    || fail "No Sparkle EdDSA key in the login Keychain; restore it with: $sparkle_bin/generate_keys -f <backup>"
  [[ $actual == "$expected" ]] || fail "The Sparkle key in the Keychain ($actual) does not match SUPublicEDKey ($expected)."

  # Sparkle compares CFBundleVersion, so every release needs a higher build number than the live feed.
  if live=$(curl -fsL "$feed_url" 2>/dev/null); then
    live_build=$(sed -n 's/.*<sparkle:version>\([^<]*\)<.*/\1/p' <<< "$live" | sed -n 1p)
    if [[ -n $live_build ]] && (( build <= live_build )); then
      fail "CURRENT_PROJECT_VERSION ($build) must be greater than the published build ($live_build); run make bump."
    fi
  fi
fi

if $publish; then
  need gh "brew install gh"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in; run gh auth login."
  [[ -z $(git status --porcelain) ]] || fail "The working tree has uncommitted changes; commit them before publishing."
  git fetch --quiet origin
  [[ -n $(git branch -r --contains HEAD) ]] || fail "HEAD is not on origin; push it before publishing."
  if is_draft=$(gh release view "$tag" -R "$repo" --json isDraft --jq .isDraft 2>/dev/null); then
    [[ $is_draft == true ]] && fail "A draft GitHub release $tag already exists. Check it with make verify-release \
and publish it with make go-live, or delete it: gh release delete $tag -R $repo"
    fail "GitHub release $tag already exists; raise the version with make bump VERSION=<x.y.z>."
  fi
fi

# --- Release: Developer ID–signed app and zip in build/release ---

# The source state, recorded before building so BUILD_INFO describes what was built.
commit=$(git rev-parse HEAD)
dirty=$([[ -n $(git status --porcelain) ]] && echo yes || echo no)
xcode=$(xcodebuild -version | paste -sd ' ' -)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# write_info <dir> <notarized> <files...>: BUILD_INFO and SHA256SUMS for one output folder.
write_info() {
  local dir=$1 notarized=$2; shift 2
  cat > "$dir/BUILD_INFO" <<INFO
PRODUCT=MaskPad
VERSION=$version
BUILD=$build
COMMIT=$commit
DIRTY=$dirty
BUILT_AT=$built_at
XCODE=$xcode
ARCHS=$(lipo -archs "$app/Contents/MacOS/MaskPad")
SIGNED_BY=$identity
NOTARIZED=$notarized
INFO
  (cd "$dir" && shasum -a 256 "$@" > SHA256SUMS)
}

# Copies of the app get registered with Launch Services, and the app launcher may then show one of them
# instead of the installed app. Copies that stay on disk are registered again soon after, so the only
# lasting copy is the output in build/release: the export is moved there, and the stapled copy and the
# DMG mount are gone before the script exits and unregisters what was under build/intermediates. Old
# copies are unregistered before they are deleted.
"$root/Scripts/unregister_apps.sh" "$work" "$release_dir"
rm -rf "$work" "$release_dir"
mkdir -p "$work" "$release_dir"
trap '"$root/Scripts/unregister_apps.sh" "$work"' EXIT

step "Archiving MaskPad $version ($build)"
"${xcodebuild[@]}" archive -destination "generic/platform=macOS" -archivePath "$archive" \
  -derivedDataPath "$work/DerivedData" -quiet

step "Exporting with Developer ID"
cat > "$work/ExportOptions.plist" <<PLIST
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
  -exportOptionsPlist "$work/ExportOptions.plist" -quiet
app=$release_dir/MaskPad.app
mv "$export_dir/MaskPad.app" "$app"

step "Checking the signature"
# Command output is captured before matching: with pipefail, `codesign | grep -q` can fail when grep exits
# early and codesign gets SIGPIPE.
codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
[[ $details == *"flags="*"runtime"* ]] || fail "Hardened runtime is missing."
[[ $details == *$'\nTimestamp='* ]] || fail "Secure timestamp is missing."
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
[[ $entitlements != *get-task-allow* ]] || fail "The get-task-allow entitlement must not ship."
# Sparkle's helpers are re-signed on export; each must carry our team ID or Sparkle refuses to install.
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
for helper in "$sparkle/Autoupdate" "$sparkle/Updater.app" "$sparkle"/XPCServices/*.xpc(N); do
  helper_details=$(codesign -dvv "$helper" 2>&1)
  [[ $'\n'$helper_details$'\n' == *$'\nTeamIdentifier='"$team"$'\n'* ]] || fail "$helper is not signed by team $team."
done

identity=$(sed -n '/^Authority=/{s///p;q;}' <<< "$details")
# Named apart from the notarized zip in build/dist, so the two are never mixed up.
ditto -c -k --keepParent "$app" "$release_dir/MaskPad-$version-unnotarized.zip"
write_info "$release_dir" no "MaskPad-$version-unnotarized.zip"

if ! $notarize; then
  step "MaskPad $version ($build): signed, not notarized"
  echo "    $release_dir"
  sed 's/^/    /' "$release_dir/SHA256SUMS"
  exit 0
fi

# --- Dist: notarized DMG and zip and the appcast in build/dist ---

rm -rf "$dist_dir"
mkdir -p "$dist_dir"
dmg=$dist_dir/MaskPad-$version.dmg
zip=$dist_dir/MaskPad-$version.zip

step "Packaging the DMG"
# dmgbuild still calls hdiutil verbs that print deprecation warnings; drop only those.
"${dmgbuild[@]}" -s Scripts/dmg_settings.py -D app="$app" -D art="$dmg_art" MaskPad "$dmg" \
  >/dev/null 2> >(grep -v 'is deprecated' >&2)
codesign --sign "$identity" --timestamp "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify -quiet "$dmg"
# The app as users will copy it: the DMG layout must not add Finder info or other detritus to the bundle.
mnt=$work/dmg-mount
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg"
dmg_app_ok=true
codesign --verify --deep --strict "$mnt/MaskPad.app" || dmg_app_ok=false
hdiutil detach -quiet "$mnt"
$dmg_app_ok || fail "The app inside the DMG fails strict signature verification."

# One submission covers both: notarizing the DMG also records the app inside it, so a copy of the same
# app can be stapled too and zipped for Sparkle. build/release keeps the unstapled app.
step "Notarizing (profile: $profile; this usually takes a few minutes)"
result=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json)
submission=$(plutil -extract id raw - <<< "$result")
notary_status=$(plutil -extract status raw - <<< "$result")
if [[ $notary_status != Accepted ]]; then
  xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
  fail "Notarization finished with status \"$notary_status\" (submission $submission)."
fi
stapled=$work/stapled/MaskPad.app
ditto "$app" "$stapled"
xcrun stapler staple -q "$dmg"
xcrun stapler staple -q "$stapled"
spctl -a -t open --context context:primary-signature "$dmg"
spctl -a -t exec "$stapled"
ditto -c -k --keepParent "$stapled" "$zip"
rm -r "${stapled:h}"

step "Generating the appcast"
# Each release's appcast lists only that release; the feed URL always resolves to the latest one.
staging=$work/appcast
mkdir -p "$staging"
cp "$zip" "$staging/"
# Only the English notes go to generate_appcast, which embeds the .md file named like the archive; it
# would turn MaskPad-<version>.<lang>.md files into links to separately hosted notes. The other languages
# are embedded afterwards.
if $english_notes; then
  cp "$notes" "$staging/MaskPad-$version.md"
fi
"$sparkle_bin/generate_appcast" --embed-release-notes --maximum-versions 1 \
  --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
  --link "https://github.com/$repo" -o "$dist_dir/appcast.xml" "$staging"
grep -q 'sparkle:edSignature=' "$dist_dir/appcast.xml" || fail "The appcast is not EdDSA-signed."
if $english_notes; then
  PYTHONDONTWRITEBYTECODE=1 python3 Scripts/localize_appcast.py "$dist_dir/appcast.xml" "$version" | sed 's/^/    /'
fi
write_info "$dist_dir" "yes (submission $submission)" "${dmg:t}" "${zip:t}"

step "MaskPad $version ($build): signed and notarized"
echo "    $dist_dir"
sed 's/^/    /' "$dist_dir/SHA256SUMS"

if $publish; then
  # A draft is invisible to users, and releases/latest (the Sparkle feed) skips it, so nothing ships until
  # make go-live. The tag is created at this commit when the draft is published.
  step "Creating draft GitHub release $tag"
  draft_url=$(gh release create "$tag" "$dmg" "$zip" "$dist_dir/appcast.xml" "$dist_dir/SHA256SUMS" -R "$repo" \
    --draft --target "$commit" --title "MaskPad $version" --notes-file "$notes")
  echo "    $draft_url"
  echo "    Not live yet. Check it with make verify-release, then publish it with make go-live."
else
  echo "    Publish a draft with: make publish"
fi
exit 0
