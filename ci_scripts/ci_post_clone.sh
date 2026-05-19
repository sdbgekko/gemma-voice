#!/bin/sh
set -eu

# Xcode Cloud provides CI_BUILD_NUMBER — a monotonically-increasing integer
# per workflow run. Stamp it into Info.plist so every archive has a unique
# CFBundleVersion. Without this, App Store Connect rejects duplicate uploads.

# Find the repo root. Apple docs are inconsistent — different workflows
# expose either CI_PRIMARY_REPOSITORY_PATH or CI_WORKSPACE. Try both, and
# fall back to the script's parent dir.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}}"

echo "ci_post_clone: REPO_ROOT=$REPO_ROOT"
echo "ci_post_clone: CI_BUILD_NUMBER=${CI_BUILD_NUMBER:-(unset)}"

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "ci_post_clone: CI_BUILD_NUMBER unset — skipping"
  exit 0
fi

# Bump CFBundleVersion in every embedded Info.plist. App-extension
# bundles (widgets, watch app) MUST match the parent's CFBundleVersion
# or ExportArchiveStep fails with:
#   "The CFBundleVersion of an app extension ('25') must match that of
#    its containing parent app ('71')"
for PLIST in \
  "$REPO_ROOT/Resources/Info.plist" \
  "$REPO_ROOT/WidgetResources/Info.plist" \
  "$REPO_ROOT/WatchResources/Info.plist"; do
  if [ -f "$PLIST" ]; then
    echo "Setting CFBundleVersion=$CI_BUILD_NUMBER in $PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$PLIST"
  else
    echo "ci_post_clone: $PLIST not found — skipping"
  fi
done
