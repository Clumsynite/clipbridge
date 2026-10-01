#!/usr/bin/env bash
# Bump VERSION (and the README badge) and commit. Pushing that commit to main releases it:
# CI runs, and on success the Release workflow builds and publishes v<version>. Never tag by hand.
#
#   scripts/bump-version.sh patch|minor|major|X.Y.Z
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
cur=$(tr -d '[:space:]' < VERSION)
IFS=. read -r maj min pat <<< "$cur"
case ${1:?usage: bump-version.sh patch|minor|major|X.Y.Z} in
  patch) new="$maj.$min.$((pat + 1))" ;;
  minor) new="$maj.$((min + 1)).0" ;;
  major) new="$((maj + 1)).0.0" ;;
  *)
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not x.y.z: $1" >&2; exit 1; }
    new=$1 ;;
esac
[[ -z $(git status --porcelain) ]] || { echo "commit or stash your changes first" >&2; exit 1; }
printf '%s\n' "$new" > VERSION
sed -i '' -E "s#(badge/version-)[0-9]+\.[0-9]+\.[0-9]+(-blue)#\1$new\2#" README.md
git add VERSION README.md
git commit -qm "Release v$new"
echo "v$cur -> v$new committed. Push to main to release: git push"
