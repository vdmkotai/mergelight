#!/bin/bash
# Builds dist/Mergelight.app.
#
#   scripts/build-app.sh           universal release build, signed with your Developer ID if present
#   scripts/build-app.sh --run     same, then (re)launches the app
#
# Environment:
#   VERSION            marketing version (default 0.1.0)
#   SIGN_IDENTITY      codesign identity; default: first "Developer ID Application", else ad-hoc
#   GITHUB_CLIENT_ID   OAuth App client ID for "Sign in with GitHub" (device flow); optional
#   NOTARY_PROFILE     notarytool keychain profile; when set, the app is notarized and stapled
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
BUNDLE_ID=io.github.vdmkotai.mergelight
GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID:-}
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BINARY="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Mergelight"

mkdir -p dist
STAGE=$(mktemp -d "$PWD/dist/.build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Mergelight.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Mergelight"
strip -x "$APP/Contents/MacOS/Mergelight"

ICON_CACHE=.build/AppIcon.icns
if [[ ! -f "$ICON_CACHE" || scripts/make-icon.swift -nt "$ICON_CACHE" ]]; then
  swift scripts/make-icon.swift "$STAGE/AppIcon.iconset"
  iconutil -c icns "$STAGE/AppIcon.iconset" -o "$ICON_CACHE"
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mergelight</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Mergelight</string>
<key>CFBundleDisplayName</key><string>Mergelight</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Vadym Kotai. MIT License.</string>
<key>MergelightGitHubClientID</key><string>$GITHUB_CLIENT_ID</string>
</dict></plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "No Developer ID found; signing ad-hoc."
  codesign --force --sign - "$APP"
else
  echo "Signing with: $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/Mergelight.zip"
  xcrun notarytool submit "$STAGE/Mergelight.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

# Swap in atomically; a running copy keeps its old files until it quits.
rm -rf dist/Mergelight.app.old
[[ -d dist/Mergelight.app ]] && mv dist/Mergelight.app dist/Mergelight.app.old
mv "$APP" dist/Mergelight.app
rm -rf dist/Mergelight.app.old
echo "Built $PWD/dist/Mergelight.app ($VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Mergelight 2>/dev/null && sleep 0.5 || true
  open dist/Mergelight.app
fi
