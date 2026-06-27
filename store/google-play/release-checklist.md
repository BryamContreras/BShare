# BShare Google Play Release Checklist

- Package name: `com.bshare.bshare`
- App name: `BShare`
- Version: read from `pubspec.yaml`
- Release artifact: Android App Bundle (`.aab`)
- Signing: private upload key configured in `android/key.properties`
- Category suggestion: Tools
- Contains ads: No
- App access: No login required
- Target audience: choose the correct audience for your intended users
- Content rating: complete Play questionnaire
- Privacy policy: public URL required
- Data safety: see `data-safety.md`
- Screenshots: required in Play Console
- Feature graphic: recommended by Play Console
- Short/full descriptions: available in `fastlane/metadata/android`

Release command:

```powershell
.\scripts\build_releases.ps1 -SkipWindows
```
