# Release Guide

## Build Release Artifacts On Windows

```powershell
.\scripts\build_releases.ps1
```

This creates:

- Android APK
- Android App Bundle for Google Play
- Windows x64 release folder
- Windows x64 ZIP
- Linux/macOS placeholder notes, because those releases require native hosts
- `manifest.json` describing generated artifacts

Output folder:

```text
dist/releases/BShare-<version>
```

`dist/` is ignored by Git so build artifacts do not get pushed with source code.

## Windows Installer

Install Inno Setup, then run:

```powershell
iscc .\installer\windows\BShare.iss
```

or:

```powershell
.\scripts\build_releases.ps1 -BuildInstaller
```

The installer script sets:

```ini
UninstallDisplayName=BShare
```

so Windows uninstall views do not show the app version in the uninstall display name.

## Linux Release

Run on Linux:

```bash
./scripts/build_releases.sh --linux-only
```

This creates a Linux x64 bundle, `.tar.gz`, and distributable `.deb` under
`dist/releases/BShare-<version>/linux`. The `.deb` targets Debian 13, Ubuntu
24.04 or newer, and their amd64-based derivatives.

## macOS Release

Run on macOS:

```bash
./scripts/build_releases.sh --macos-only
```

This creates a zipped `.app` under `dist/releases/BShare-<version>/macos`.

## Google Play

Create an upload key:

```powershell
.\scripts\create_android_upload_key.ps1
```

Then rebuild:

```powershell
.\scripts\build_releases.ps1 -SkipWindows
```

Upload:

```text
dist/releases/BShare-<version>/android/BShare-<version>-google-play.aab
```

Use the checklist and Data Safety notes in `store/google-play`.

## GitHub

This checkout was not a Git repo when the release setup was created. To publish source code:

```powershell
git init -b main
git add .
git commit -m "Initial BShare release"
git remote add origin https://github.com/<owner>/<repo>.git
git push -u origin main
```

If you prefer GitHub CLI:

```powershell
winget install GitHub.cli
gh auth login
gh repo create <owner>/<repo> --private --source . --remote origin --push
```
