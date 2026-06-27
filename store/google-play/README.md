# Google Play Package

This folder contains the Play Store preparation notes for BShare.

Generated release artifact:

- `dist/releases/BShare-<version>/android/BShare-<version>-google-play.aab`

Before uploading to Google Play:

1. Create an Android upload key:

   ```powershell
   .\scripts\create_android_upload_key.ps1
   ```

2. Rebuild the Play bundle:

   ```powershell
   .\scripts\build_releases.ps1 -SkipWindows
   ```

3. Upload the generated `.aab` to Play Console.

4. Fill the store listing using `fastlane/metadata/android`.

5. Add screenshots for phone, tablet if desired, and any required form factors.

6. Publish a privacy policy page and paste its public URL in Play Console.

7. Complete Data safety using `store/google-play/data-safety.md`.

8. Complete content rating and target audience forms in Play Console.

Important:

- Do not upload `android/key.properties` or `android/*.jks` to GitHub.
- The fallback debug-signed release builds are only for local testing. Play upload should use your private upload key.
