#!/bin/bash
set -euo pipefail

VERSION="${1:?Release version required}"
KEYCHAIN="${2:?Signing keychain required}"
OUTPUT_DIRECTORY="${3:-dist}"
PHASE="${4:-complete}"
APP_BUNDLE="$OUTPUT_DIRECTORY/SpaceMonger for Mac.app"
ARCHIVE="$OUTPUT_DIRECTORY/SpaceMonger-for-Mac-$VERSION.zip"
SUBMISSION="$OUTPUT_DIRECTORY/notarization-submission.json"
RESULT="$OUTPUT_DIRECTORY/notarization-result.json"
AUTH=(--keychain-profile release-notary --keychain "$KEYCHAIN")
[[ "$PHASE" == submit || "$PHASE" == finish || "$PHASE" == complete ]]

if [[ "$PHASE" != finish ]]; then
    # Save the submission UUID before waiting, including when Apple takes hours.
    xcrun notarytool submit "$ARCHIVE" "${AUTH[@]}" --output-format json > "$SUBMISSION"
    jq -e '.id | test("^[0-9a-fA-F-]{36}$")' "$SUBMISSION" > /dev/null
    shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$OUTPUT_DIRECTORY/archive.sha256"
    cat "$SUBMISSION"
fi
if [[ "$PHASE" == submit ]]; then
    exit 0
fi

submission_id="$(jq -er '.id | select(test("^[0-9a-fA-F-]{36}$"))' "$SUBMISSION")"
expected="$(cat "$OUTPUT_DIRECTORY/archive.sha256")"
actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || { echo "Submitted archive checksum mismatch" >&2; exit 1; }

# wait may return an empty stdout on timeout. Read status separately as JSON.
xcrun notarytool wait "$submission_id" "${AUTH[@]}" --timeout 40m || true
xcrun notarytool info "$submission_id" "${AUTH[@]}" --output-format json > "$RESULT"
cat "$RESULT"
status="$(jq -er '.status' "$RESULT")"
if [[ "$status" == Accepted || "$status" == Invalid ]]; then
    xcrun notarytool log "$submission_id" "${AUTH[@]}" "$OUTPUT_DIRECTORY/notarization-log.json"
    cat "$OUTPUT_DIRECTORY/notarization-log.json"
fi
if [[ "$status" != Accepted ]]; then
    echo "Notarization status: $status ($submission_id). No release published." >&2
    echo "If still In Progress, re-run this GitHub run later to resume the saved submission." >&2
    exit 1
fi

# Always verify and ship the exact submitted app, including on a resumed run.
rm -rf "$APP_BUNDLE"
ditto -x -k "$ARCHIVE" "$OUTPUT_DIRECTORY"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

# ZIPs cannot be stapled; ship a new ZIP containing the stapled app.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
echo "Created signed and notarized archive: $ARCHIVE"
