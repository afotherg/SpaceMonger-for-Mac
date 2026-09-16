#!/bin/bash
set -euo pipefail

VERSION="${1:?Release version required}"
KEYCHAIN="${2:?Signing keychain required}"
OUTPUT_DIRECTORY="${3:-dist}"
APP_BUNDLE="$OUTPUT_DIRECTORY/SpaceMonger for Mac.app"
ARCHIVE="$OUTPUT_DIRECTORY/SpaceMonger-for-Mac-$VERSION.zip"
RESULT="$OUTPUT_DIRECTORY/notarization-result.json"
AUTH=(--keychain-profile release-notary --keychain "$KEYCHAIN")

# A failure, rejection, or timeout must never publish the unnotarized ZIP.
submit_status=0
xcrun notarytool submit "$ARCHIVE" "${AUTH[@]}" --wait --timeout 40m --output-format json > "$RESULT" || submit_status=$?
cat "$RESULT"
submission_id="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "${AUTH[@]}" "$OUTPUT_DIRECTORY/notarization-log.json" || true
fi
if [[ "$submit_status" != 0 || "$status" != Accepted ]]; then
    echo "Notarization did not finish with Accepted status. See submission $submission_id." >&2
    if [[ -f "$OUTPUT_DIRECTORY/notarization-log.json" ]]; then
        cat "$OUTPUT_DIRECTORY/notarization-log.json"
    fi
    exit 1
fi

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

# ZIPs cannot be stapled; ship a new ZIP containing the stapled app.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
echo "Created signed and notarized archive: $ARCHIVE"
