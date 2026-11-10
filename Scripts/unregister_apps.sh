#!/bin/zsh
# Removes Launch Services registrations of apps under the given directories, including ones that have
# already been deleted. Every copy of MaskPad that macOS sees (build output, unpacked zips, mounted DMGs)
# is registered under the same bundle ID, and the app launcher shows only one of them, sometimes a stale
# copy instead of /Applications/MaskPad.app. Used by make clean, Scripts/release.sh and
# Scripts/github_release.sh; it never touches registrations outside the given directories.
#
#   Scripts/unregister_apps.sh <dir>...
set -euo pipefail

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
(( $# )) || exit 0

# Launch Services records resolved paths (/private/var/..., not /var/...).
prefixes=()
for dir in "$@"; do
  if [[ -e $dir ]]; then
    prefixes+=("${dir:A}/")
  else
    # Already deleted, so symlinks can't be resolved; /var and /tmp are links into /private.
    prefixes+=("${dir:a}/")
    [[ ${dir:a} == /(var|tmp)/* ]] && prefixes+=("/private${dir:a}/")
  fi
done

registered=$("$lsregister" -dump 2>/dev/null | sed -n 's/^path: *\(.*\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u)
for app in ${(f)registered}; do
  for prefix in $prefixes; do
    if [[ $app == "$prefix"* ]]; then
      "$lsregister" -u "$app" 2>/dev/null || true
      break
    fi
  done
done
