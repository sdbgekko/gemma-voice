#!/bin/sh
set -eu

# Xcode Cloud provides CI_BUILD_NUMBER — a monotonically-increasing integer
# per workflow run. Stamp it into Info.plist so every archive has a unique
# CFBundleVersion. Without this, App Store Connect rejects duplicate uploads.

# Find the repo root. Apple docs are inconsistent — different workflows
# expose either CI_PRIMARY_REPOSITORY_PATH or CI_WORKSPACE. Try both, and
# fall back to the script's parent dir.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}}"
INFO_PLIST="$REPO_ROOT/Resources/Info.plist"

echo "ci_post_clone: REPO_ROOT=$REPO_ROOT"
echo "ci_post_clone: INFO_PLIST=$INFO_PLIST"
echo "ci_post_clone: CI_BUILD_NUMBER=${CI_BUILD_NUMBER:-(unset)}"

if [ ! -f "$INFO_PLIST" ]; then
  echo "ci_post_clone: Info.plist not found — skipping"
  exit 0
fi

if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  echo "Setting CFBundleVersion=$CI_BUILD_NUMBER"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$INFO_PLIST"
fi
