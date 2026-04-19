#!/bin/sh
set -euo pipefail

# Xcode Cloud provides CI_BUILD_NUMBER — a monotonically-increasing integer
# per workflow run. Stamp it into Info.plist so every archive has a unique
# CFBundleVersion. Without this, App Store Connect rejects duplicate uploads.
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  INFO_PLIST="$CI_WORKSPACE/Resources/Info.plist"
  echo "Setting CFBundleVersion=$CI_BUILD_NUMBER in $INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$INFO_PLIST"
fi
