# Releasing

## One-time setup

1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/).
2. In Xcode, open **Settings → Accounts**, add your Apple ID, click **Manage Certificates**, and create a **Developer ID Application** certificate.
3. Find the exact identity name:

   ```bash
   security find-identity -v -p codesigning
   ```

4. Create an app-specific password at [account.apple.com](https://account.apple.com) under **Sign-In and Security → App-Specific Passwords**, then store notarization credentials in your keychain:

   ```bash
   xcrun notarytool store-credentials notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

## Building a release

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary scripts/release.sh 1.2.0
```

This compiles a universal FFmpeg (Apple Silicon and Intel) if needed, signs everything with the hardened runtime, builds the DMG, submits it to Apple, staples the notarization ticket, and writes the DMG and the matching FFmpeg source archive to `dist/`. Without `SIGN_IDENTITY` and `NOTARY_PROFILE` it produces an ad-hoc signed DMG instead.

## Publishing

```bash
gh release create v1.2.0 dist/ConvertMac-1.2.0.dmg dist/ffmpeg-sources-1.2.0.tar --title "ConvertMac 1.2.0"
```

Then update `version` and `sha256` in `Casks/convertmac.rb` in [convertmac/homebrew-tap](https://github.com/convertmac/homebrew-tap) using the checksum printed by the release script.
