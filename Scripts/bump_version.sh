#!/bin/zsh
# Prepares the next release: sets MARKETING_VERSION, raises CURRENT_PROJECT_VERSION by one, and creates
# docs/release-notes/<version>.md from a template if it does not exist. Run it with make bump.
#
#   Scripts/bump_version.sh 1.0.1   # make bump VERSION=1.0.1: new version, next build number
#   Scripts/bump_version.sh         # make bump: same version, next build number only
#
# Sparkle compares the build number, so every release needs a higher one; the version must not go down.
# Nothing is committed: review the change, write the release notes, then commit.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
fail() { echo "error: $*" >&2; exit 1; }

current_version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
current_build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' project.yml)
[[ $current_version == <->.<->.<-> && $current_build == <-> ]] \
  || fail "Could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml."

version=${1:-$current_version}
[[ $version == <->.<->.<-> ]] || fail "VERSION must look like 1.2.3, not \"$version\"."
# Compare major.minor.patch numerically.
new=(${(s:.:)version}) old=(${(s:.:)current_version})
for i in 1 2 3; do
  (( new[i] > old[i] )) && break
  (( new[i] < old[i] )) && fail "VERSION $version is lower than the current $current_version."
done
build=$((current_build + 1))

sed -i '' \
  -e "s/^\( *MARKETING_VERSION: \)\"$current_version\"$/\1\"$version\"/" \
  -e "s/^\( *CURRENT_PROJECT_VERSION: \)\"$current_build\"$/\1\"$build\"/" \
  project.yml
echo "MARKETING_VERSION        $current_version -> $version"
echo "CURRENT_PROJECT_VERSION  $current_build -> $build"

# The TODO line marks an unedited template; make publish refuses release notes that still contain it.
notes=docs/release-notes/$version.md
if [[ ! -f $notes ]]; then
  mkdir -p "${notes:h}"
  cat > "$notes" <<NOTES
TODO: describe what changed in MaskPad $version, then delete this line.

-
NOTES
  echo "Created $notes"
fi

echo
echo "Next: write $notes, commit, push, then make publish."
