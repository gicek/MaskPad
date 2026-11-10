#!/bin/zsh
# Checks and publishes the GitHub release that make publish creates as a draft.
#
#   Scripts/github_release.sh verify [version]    # make verify-release [VERSION=x.y.z]
#   Scripts/github_release.sh go-live [version]   # make go-live [VERSION=x.y.z]
#
# verify downloads the release's assets (a draft too) and checks what users and Sparkle will get:
# - the assets are all there and match the release's SHA256SUMS
# - the DMG and the app in the zip are signed by Developer ID, notarized, stapled and accepted by
#   Gatekeeper, and both carry this version and build
# - appcast.xml lists exactly this version and build, points at this release's zip with its real size,
#   and its EdDSA signature verifies (needs the Sparkle key in the login Keychain)
# - once published: the live feed (releases/latest/download/appcast.xml) is this release's appcast
#
# go-live runs verify, publishes the draft as the latest release (which creates the tag), and waits until
# the live feed serves the new appcast. From then on, installed copies offer the update.
#
# The version defaults to MARKETING_VERSION in project.yml.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
mode=${1:-}
[[ $mode == verify || $mode == go-live ]] || { echo "usage: Scripts/github_release.sh verify|go-live [version]" >&2; exit 2; }

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }
ok() { echo "    ok: $*"; }

repo=gicek/MaskPad
feed_url=https://github.com/$repo/releases/latest/download/appcast.xml
sparkle_bin=$root/build/SourcePackages/artifacts/sparkle/Sparkle/bin
version=${2:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)}
tag=v$version
dmg_name=MaskPad-$version.dmg
zip_name=MaskPad-$version.zip

command -v gh >/dev/null || fail "gh is missing; brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in; run gh auth login."
[[ -x $sparkle_bin/sign_update ]] || fail "Sparkle's tools are missing; run make build once to fetch them."

is_draft=$(gh release view "$tag" -R "$repo" --json isDraft --jq .isDraft 2>/dev/null) \
  || fail "No GitHub release $tag; create a draft with make publish."
release_url=$(gh release view "$tag" -R "$repo" --json url --jq .url)
asset_names=$(gh release view "$tag" -R "$repo" --json assets --jq '.assets[].name')

# Set at the top level: in zsh, an EXIT trap set inside a function runs when the function returns.
# The unpacked and mounted copies get registered with Launch Services; drop them before deleting.
tmp=$(mktemp -d)
# Each step may fail (the DMG is usually detached already); with set -e, a failure would end the trap.
trap 'hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true; "$root/Scripts/unregister_apps.sh" "$tmp" || true; rm -rf "$tmp"' EXIT

# app_version <app>: "<CFBundleShortVersionString> (<CFBundleVersion>)"
app_version() {
  local plist=$1/Contents/Info.plist
  echo "$(plutil -extract CFBundleShortVersionString raw "$plist") ($(plutil -extract CFBundleVersion raw "$plist"))"
}
# check_app <app> <label>: signed by Developer ID, stapled, accepted by Gatekeeper, right version.
check_app() {
  codesign --verify --deep --strict "$1" || fail "$2: the signature does not verify."
  xcrun stapler validate -q "$1" || fail "$2: no notarization ticket is stapled."
  spctl -a -t exec "$1" 2>/dev/null || fail "$2: Gatekeeper rejects it."
  [[ $(app_version "$1") == "$version ($build)" ]] || fail "$2 is $(app_version "$1"), expected $version ($build)."
}

verify() {
  step "Verifying GitHub release $tag ($([[ $is_draft == true ]] && echo draft || echo published))"
  echo "    $release_url"

  # Assets and checksums.
  for name in "$dmg_name" "$zip_name" appcast.xml SHA256SUMS; do
    [[ $'\n'$asset_names$'\n' == *$'\n'$name$'\n'* ]] || fail "The release has no $name."
  done
  gh release download "$tag" -R "$repo" -D "$tmp/assets" -p "$dmg_name" -p "$zip_name" -p appcast.xml -p SHA256SUMS
  (cd "$tmp/assets" && shasum -a 256 -c --quiet SHA256SUMS) || fail "An asset does not match SHA256SUMS."
  ok "assets present and matching SHA256SUMS"

  # The appcast: one item, this version, this release's zip, real size, valid EdDSA signature.
  local appcast=$tmp/assets/appcast.xml
  xpath() { xmllint --xpath "$1" "$appcast" 2>/dev/null || true; }
  [[ $(xpath 'count(//item)') == 1 ]] || fail "appcast.xml should list exactly one update."
  build=$(xpath 'string(//item/*[local-name()="version"])')
  local short=$(xpath 'string(//item/*[local-name()="shortVersionString"])')
  local url=$(xpath 'string(//item/enclosure/@url)')
  local length=$(xpath 'string(//item/enclosure/@length)')
  local signature=$(xpath 'string(//item/enclosure/@*[local-name()="edSignature"])')
  [[ $short == "$version" && $build == <-> ]] || fail "appcast.xml is for $short ($build), expected $version."
  [[ $url == "https://github.com/$repo/releases/download/$tag/$zip_name" ]] || fail "appcast.xml points at $url."
  [[ $length == $(stat -f %z "$tmp/assets/$zip_name") ]] || fail "appcast.xml gives the zip size as $length."
  "$sparkle_bin/sign_update" --verify "$tmp/assets/$zip_name" "$signature" >/dev/null 2>&1 \
    || fail "The zip's EdDSA signature in appcast.xml does not verify."
  ok "appcast.xml: $version ($build), $zip_name, $length bytes, EdDSA signature valid"

  # The zip Sparkle installs.
  ditto -x -k "$tmp/assets/$zip_name" "$tmp/zip"
  check_app "$tmp/zip/MaskPad.app" "$zip_name"
  ok "$zip_name: MaskPad $version ($build), Developer ID, notarized and stapled"

  # The DMG people download, and the app inside it.
  codesign --verify --strict "$tmp/assets/$dmg_name" || fail "$dmg_name: the signature does not verify."
  xcrun stapler validate -q "$tmp/assets/$dmg_name" || fail "$dmg_name: no notarization ticket is stapled."
  spctl -a -t open --context context:primary-signature "$tmp/assets/$dmg_name" 2>/dev/null \
    || fail "$dmg_name: Gatekeeper rejects it."
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$tmp/assets/$dmg_name"
  [[ -L $tmp/mnt/Applications ]] || fail "$dmg_name has no Applications link."
  codesign --verify --deep --strict "$tmp/mnt/MaskPad.app" || fail "The app in $dmg_name does not verify."
  [[ $(app_version "$tmp/mnt/MaskPad.app") == "$version ($build)" ]] \
    || fail "The app in $dmg_name is $(app_version "$tmp/mnt/MaskPad.app")."
  hdiutil detach -quiet "$tmp/mnt"
  ok "$dmg_name: Developer ID, notarized and stapled, MaskPad $version ($build) inside"

  if [[ $is_draft == true ]]; then
    [[ $mode == go-live ]] || echo "    Draft: not live yet. Publish it with make go-live."
  else
    check_live || fail "The live feed $feed_url does not serve this release's appcast."
    ok "live feed serves $version ($build)"
  fi
}

# check_live: whether the live Sparkle feed is this release's appcast.
check_live() {
  local live
  live=$(curl -fsL "$feed_url" 2>/dev/null) || return 1
  [[ $live == "$(< "$tmp/assets/appcast.xml")" ]]
}

verify
if [[ $mode == go-live ]]; then
  [[ $is_draft == true ]] || { echo "==> $tag is already published."; exit 0; }
  step "Publishing $tag as the latest release"
  gh release edit "$tag" -R "$repo" --draft=false --latest >/dev/null
  # GitHub serves releases/latest from a cache for a short while.
  for attempt in {1..24}; do
    check_live && break
    (( attempt == 24 )) && fail "Published, but after 2 minutes the live feed still does not serve $tag's appcast; check $feed_url."
    sleep 5
  done
  git fetch --quiet --tags origin
  ok "live: installed copies of MaskPad now offer $version ($build)"
  echo "    $(gh release view "$tag" -R "$repo" --json url --jq .url)"
fi
