#!/bin/bash

set -euo pipefail

VERSION="${1:-0.0.0}"
OUTPUT_DIRECTORY="${2:-dist}"
MODE="${3:-developer-id}"
APP_NAME="SpaceMonger for Mac"
APP_BUNDLE="$OUTPUT_DIRECTORY/$APP_NAME.app"
ARCHIVE="$OUTPUT_DIRECTORY/SpaceMonger-for-Mac-$VERSION.zip"
DISPLAY_VERSION="${VERSION#v}"
DISPLAY_VERSION="${DISPLAY_VERSION%%-*}"
DISPLAY_VERSION="${DISPLAY_VERSION%%+*}"
BUILD_VERSION="$(printf '%s' "$DISPLAY_VERSION" | tr -cd '0-9.')"

if [[ "$MODE" != developer-id && "$MODE" != app-store ]]; then
    echo "Mode must be developer-id or app-store" >&2
    exit 2
fi
if [[ "$MODE" == app-store ]]; then
    : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to an Apple Distribution identity}"
    : "${INSTALLER_SIGNING_IDENTITY:?Set INSTALLER_SIGNING_IDENTITY to a Mac Installer Distribution identity}"
    : "${APP_STORE_PROVISIONING_PROFILE:?Set APP_STORE_PROVISIONING_PROFILE to the SpaceMonger Mac App Store profile}"
    [[ -f "$APP_STORE_PROVISIONING_PROFILE" ]] || { echo "Provisioning profile not found" >&2; exit 2; }
fi

if [[ -z "$BUILD_VERSION" ]]; then
    BUILD_VERSION="1"
fi

swift build -c release --arch arm64 --arch x86_64
BIN_DIRECTORY="$(swift build -c release --show-bin-path --arch arm64 --arch x86_64)"

rm -rf "$APP_BUNDLE"
if [[ "$MODE" == developer-id ]]; then
    rm -f "$ARCHIVE"
fi
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
    <string>12.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 SpaceMonger for Mac contributors</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
</dict>
</plist>
PLIST

if [[ "$MODE" == app-store ]]; then
    cp "$APP_STORE_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    codesign --force --timestamp --entitlements Assets/AppStore.entitlements \
        --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
elif [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
    codesign --force --sign - "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$MODE" == app-store ]]; then
    PKG="$OUTPUT_DIRECTORY/SpaceMonger-for-Mac-$VERSION.pkg"
    rm -f "$PKG"
    productbuild --component "$APP_BUNDLE" /Applications \
        --sign "$INSTALLER_SIGNING_IDENTITY" "$PKG"
    pkgutil --check-signature "$PKG"
    echo "Created $PKG"
else
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
    echo "Created $ARCHIVE"
fi
