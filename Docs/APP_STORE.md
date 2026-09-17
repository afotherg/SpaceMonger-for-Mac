# Mac App Store submission

This is a separate distribution path from the Developer ID signed, notarized GitHub release. The Mac App Store build uses App Sandbox and read/write access only to folders the user chooses in the Open panel. The read/write entitlement supports the app's Move to Trash action.

## Account setup

1. In Apple Developer, register the explicit bundle ID `com.github.afotherg.spacemonger-for-mac` for macOS. Use this exact ID in the App Store Connect app record.
2. Create **Mac App Distribution** and **Mac Installer Distribution** certificates and install both with their private keys in Keychain. The existing Developer ID certificate cannot sign this submission.
3. If the account's distribution configuration supplies a Mac App Store provisioning profile for this bundle ID, set `APP_STORE_PROVISIONING_PROFILE` to its local path before packaging.
4. Create the macOS app record in App Store Connect. Set its version to the same version passed to the package script.

## Build and upload

From the repository root, with the certificate names or SHA-1 hashes installed in Keychain:

```sh
export SIGNING_IDENTITY='Mac App Distribution: YOUR NAME (TEAMID)'
export INSTALLER_SIGNING_IDENTITY='Mac Installer Distribution: YOUR NAME (TEAMID)'
Scripts/package-app.sh v1.0.0 dist app-store
codesign -d --entitlements - 'dist/SpaceMonger for Mac.app'
```

The script creates a signed `.pkg`. Upload it with Apple's Transporter app or App Store Connect's supported upload tools. Wait for processing, select the build in the app version, complete the required metadata and App Privacy questions, then submit the version for App Review. The App Store package does not need Developer ID notarization.

Suggested initial listing copy, to edit before submission:

- **Subtitle:** See what uses your disk space
- **Description:** Explore disk usage with an interactive treemap. Choose a folder to scan, zoom into subfolders, search by name, reveal items in Finder, and move selected items to Trash. Compare allocated and logical file sizes. Scans run locally on your Mac.
- **Support URL:** `https://github.com/afotherg/SpaceMonger-for-Mac/blob/main/Docs/SUPPORT.md` (after publishing this file)
- **Privacy policy URL:** `https://github.com/afotherg/SpaceMonger-for-Mac/blob/main/Docs/PRIVACY.md` (use the repository's actual default branch after publishing this file)
- **Review note:** Choose a folder with files in the Open panel. SpaceMonger scans that folder locally and displays its contents as a treemap. The Move to Trash action requires write access to the chosen folder.

Before submission, run a sandboxed build on a Mac and verify scanning and Trash on a disposable folder selected through the Open panel. Capture at least one Mac screenshot at an accepted 16:10 size (1280 × 800, 1440 × 900, 2560 × 1600, or 2880 × 1800), confirm the public support and privacy URLs, and complete the current App Store Connect age rating, pricing, availability, and privacy fields. Set the price to free.
