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
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary scripts/release.sh 1.1.0
```

This compiles FFmpeg if needed, signs everything with the hardened runtime, builds the DMG, submits it to Apple, staples the notarization ticket, and writes the DMG and the matching FFmpeg source archive to `dist/`. Without `SIGN_IDENTITY` and `NOTARY_PROFILE` it produces an ad-hoc signed DMG instead.

## Publishing

```bash
gh release create v1.1.0 dist/Video-Audio-Converter-1.1.0.dmg dist/ffmpeg-sources-1.1.0.tar --title "Video & Audio Converter 1.1.0"
```

Then update `version` and `sha256` in `Casks/video-audio-converter.rb` in [ashrinkm/homebrew-tap](https://github.com/ashrinkm/homebrew-tap) using the checksum printed by the release script.
