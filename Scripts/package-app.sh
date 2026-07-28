#!/bin/bash

set -euo pipefail

VERSION="${1:-0.0.0}"
OUTPUT_DIRECTORY="${2:-dist}"
APP_NAME="SpaceMonger for Mac"
APP_BUNDLE="$OUTPUT_DIRECTORY/$APP_NAME.app"
ARCHIVE="$OUTPUT_DIRECTORY/SpaceMonger-for-Mac-$VERSION.zip"
DISPLAY_VERSION="${VERSION#v}"
DISPLAY_VERSION="${DISPLAY_VERSION%%-*}"
DISPLAY_VERSION="${DISPLAY_VERSION%%+*}"
BUILD_VERSION="$(printf '%s' "$DISPLAY_VERSION" | tr -cd '0-9.')"

if [[ -z "$BUILD_VERSION" ]]; then
    BUILD_VERSION="1"
fi

swift build -c release --arch arm64 --arch x86_64
BIN_DIRECTORY="$(swift build -c release --show-bin-path --arch arm64 --arch x86_64)"

rm -rf "$APP_BUNDLE" "$ARCHIVE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIRECTORY/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.github.afotherg.spacemonger-for-mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$DISPLAY_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"

echo "Created $ARCHIVE"
