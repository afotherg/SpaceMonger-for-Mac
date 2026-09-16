# Signed GitHub releases

The Create Release workflow requires a **Developer ID Application** certificate
and Apple notarization credentials. An Apple Development or Mac App Distribution
certificate does not work for this distribution method. The app uses no restricted
entitlements and does not need a provisioning profile.

## One-time account setup

1. In Xcode → Settings → Accounts, add your Apple Account and select your paid
   developer team. Choose Manage Certificates, then + → Developer ID Application.
   Alternatively create it in the Apple Developer Certificates portal using a CSR
   from Keychain Access. Keep the private key on the Mac that creates the CSR.
2. In Keychain Access → My Certificates, export that certificate **with its private
   key** as a password-protected `.p12`. Export only this signing identity.
   If exporting with OpenSSL 3, use `-keypbe PBE-SHA1-3DES
   -certpbe PBE-SHA1-3DES -macalg sha1` for macOS Keychain import compatibility.
   Verify the `.p12` imports successfully before uploading it.
3. Find your **Team ID** in Apple Developer → Membership details. Do not substitute
   the identifier shown in an Apple Development certificate name.
4. At https://account.apple.com, create an app-specific password for notarization.
   Use your Apple Account email and this app-specific password, not your normal
   account password. Complete any pending developer agreements in Apple's portal.
5. Add these repository Actions secrets at
   https://github.com/afotherg/SpaceMonger-for-Mac/settings/secrets/actions:

   | Secret | Value |
   | --- | --- |
   | `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
   | `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` |
   | `APPLE_TEAM_ID` | Your ten-character developer Team ID |
   | `APPLE_ID` | Apple Account email used for notarization |
   | `APPLE_APP_PASSWORD` | App-specific password for notarization |

   To upload the certificate without putting its contents in shell history:

   ```sh
   base64 -i /absolute/path/DeveloperID.p12 | gh secret set APPLE_CERTIFICATE_BASE64 --repo afotherg/SpaceMonger-for-Mac
   gh secret set APPLE_CERTIFICATE_PASSWORD --repo afotherg/SpaceMonger-for-Mac
   gh secret set APPLE_TEAM_ID --repo afotherg/SpaceMonger-for-Mac
   gh secret set APPLE_ID --repo afotherg/SpaceMonger-for-Mac
   gh secret set APPLE_APP_PASSWORD --repo afotherg/SpaceMonger-for-Mac
   ```

   The other commands prompt for values without including them in shell history.
   Never commit certificates, private keys, or passwords to Git.

## Release

Run **Actions → Create Release → Run workflow**, using a new version tag. The
workflow imports the certificate into a temporary keychain, validates notarization
credentials, builds a universal app, signs with hardened runtime and a secure
timestamp, then submits it to Apple. Only an Accepted result proceeds to stapling,
Gatekeeper verification, and publishing the ZIP. Credentials are removed even if
an earlier step fails. Unsigned releases are never a fallback.

Apple can take longer to process a new account's first submission. If the 40-minute
wait expires, the workflow fails without publishing. The submitted ZIP and submission
ID are saved as a GitHub Actions artifact for 30 days. Use **Re-run all jobs** on that
same run to resume the saved submission without rebuilding or uploading again.
The **Check Notarization** workflow can query a submission ID without building.
Rejected submissions include Apple's log in the failed step output. Artifacts from
an in-progress or rejected submission are not ready for distribution. Renew the certificate and update the
secrets before expiry, and replace a revoked app-specific password when needed.

The stapled ticket is inside the app, so the final ZIP supports offline Gatekeeper
verification. macOS may still show its standard downloaded-from-the-internet prompt
and request access to protected folders. Signing does not bypass those permissions.
Older release ZIPs retain their old signatures; users need the new release.

## Local builds

`Scripts/package-app.sh v1.0.0` continues to produce an ad-hoc-signed local build.
To sign locally, set `SIGNING_IDENTITY` to your Developer ID Application identity.
This alone does not notarize it. The GitHub workflow performs the full distribution
process.

References: [Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [GitHub certificate handling](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
