#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
APP="$PWD/PageCapture.app"
mkdir -p "$APP/Contents/MacOS" "$PWD/.build/module-cache"
BUILD_INPUTS="$PWD/.build/build-inputs.new"
{
  shasum -a 256 Sources/*.swift Info.plist build.command
  uname -m
  printf '%s\n' "${PAGECAPTURE_SIGNING_IDENTITY:--}"
  xcrun swiftc --version
} > "$BUILD_INPUTS"
if [[ -f "$PWD/.build/build-inputs" ]] && cmp -s "$BUILD_INPUTS" "$PWD/.build/build-inputs" && codesign --verify --strict "$APP" 2>/dev/null; then
  printf 'Unchanged; preserving existing app signature: %s\n' "$APP"
  exit 0
fi
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/CaptureCore.swift Sources/Selection.swift Sources/SelfTests.swift Sources/main.swift \
  -o "$PWD/.build/PageCapture.new" \
  -framework AppKit -framework ScreenCaptureKit -framework ApplicationServices
mv "$PWD/.build/PageCapture.new" "$APP/Contents/MacOS/PageCapture"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${PAGECAPTURE_SIGNING_IDENTITY:--}" --identifier local.pagecapture.mac "$APP"
codesign --verify --strict "$APP"
mv "$BUILD_INPUTS" "$PWD/.build/build-inputs"
printf 'Built: %s\n' "$APP"
if [[ "${PAGECAPTURE_SIGNING_IDENTITY:--}" == "-" ]]; then
  printf 'Local ad-hoc signature: after changed builds, quit the old app and re-register this app in Privacy & Security if needed.\n'
fi
