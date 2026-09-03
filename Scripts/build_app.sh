#!/bin/bash
#
# Assembles Derby.app.
#
# Derby is a plain SwiftPM package with no third-party dependencies, so the
# bundle is put together by hand here rather than by Xcode. That keeps the build
# working on machines that only have the Command Line Tools installed.
#
#   ./Scripts/build_app.sh            release build → build/Derby.app
#   ./Scripts/build_app.sh --debug    faster, unoptimised build
#   ./Scripts/build_app.sh --run      build, then launch the app
#   ./Scripts/build_app.sh --install  also copy into /Applications
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIGURATION="release"
RUN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIGURATION="debug" ;;
    --release) CONFIGURATION="release" ;;
    --run)     RUN=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Derby"
BUNDLE_ID="com.derby.gateway"
VERSION="1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building DerbyApp ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product DerbyApp

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
if [ ! -x "$BIN_PATH/DerbyApp" ]; then
  echo "error: DerbyApp binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES"

cp "$BIN_PATH/DerbyApp" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Any resource bundles SwiftPM produced (none today, but keep the app correct
# if a target later adds resources).
for bundle in "$BIN_PATH"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$RESOURCES/"
done

echo "==> Rendering app icon"
ICONSET="$OUT_DIR/$APP_NAME.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>               <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleSignature</key>             <string>????</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>NSHumanReadableCopyright</key>      <string>Derby — local AI model routing gateway</string>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Derby talks to user-configured local model servers, which are
             plain HTTP on the loopback interface or a LAN address. -->
        <key>NSAllowsLocalNetworking</key>   <true/>
    </dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signing (ad-hoc)"
# Finder/quarantine metadata makes codesign refuse the bundle.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
# An ad-hoc signature is enough for local use and for Keychain access. Replace
# "-" with a Developer ID identity to produce a distributable build.
SIGN_IDENTITY="${DERBY_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
         --options runtime --entitlements /dev/null "$APP" 2>/dev/null \
  || codesign --force --sign "$SIGN_IDENTITY" "$APP"

codesign --verify --deep --strict "$APP" && echo "    signature OK"

if [ "$INSTALL" = "1" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo
echo "Built $APP  ($SIZE)"
echo "Open it with:  open '$APP'"

if [ "$RUN" = "1" ]; then
  echo "==> Launching"
  open "$APP"
fi
