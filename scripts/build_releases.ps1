param(
    [switch]$SkipAndroid,
    [switch]$SkipWindows,
    [switch]$BuildInstaller
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root

function Get-PubspecVersion {
    $line = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(.+)$' | Select-Object -First 1
    if (-not $line) {
        throw 'Could not find version in pubspec.yaml'
    }
    return $line.Matches[0].Groups[1].Value.Trim()
}

function Reset-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedRoot = (Resolve-Path $root).Path
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $Path))
    $distRoot = [System.IO.Path]::GetFullPath((Join-Path $root 'dist'))
    if (-not $fullPath.StartsWith($distRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a path outside dist: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
}

function Copy-ReleaseFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Expected build artifact was not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$version = Get-PubspecVersion
$safeVersion = $version.Replace('+', '-')
$versionParts = $version.Split('+', 2)
$versionName = $versionParts[0]
$buildNumber = if ($versionParts.Count -gt 1) { $versionParts[1] } else { '0' }
$releaseRoot = "dist\releases\BShare-$safeVersion"
Reset-Directory $releaseRoot

$releasePath = Join-Path $root $releaseRoot
$androidPath = Join-Path $releasePath 'android'
$windowsPath = Join-Path $releasePath 'windows'
New-Item -ItemType Directory -Path $androidPath, $windowsPath -Force | Out-Null

flutter pub get

$artifacts = [System.Collections.Generic.List[string]]::new()

if (-not $SkipAndroid) {
    flutter build apk --release
    flutter build appbundle --release

    $apkName = "BShare-$safeVersion-android-release.apk"
    $aabName = "BShare-$safeVersion-google-play.aab"
    Copy-ReleaseFile 'build\app\outputs\flutter-apk\app-release.apk' (Join-Path $androidPath $apkName)
    Copy-ReleaseFile 'build\app\outputs\bundle\release\app-release.aab' (Join-Path $androidPath $aabName)
    $artifacts.Add("android/$apkName")
    $artifacts.Add("android/$aabName")
}

if (-not $SkipWindows) {
    flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Windows build failed with exit code $LASTEXITCODE."
    }

    # The shared packager includes the app-local Microsoft C++ runtime and
    # compiles the same installer used in GitHub Actions.
    & (Join-Path $root 'packaging/windows/build-installer.ps1') -OutputDirectory "$releaseRoot\windows" -Version $versionName -BuildNumber $buildNumber -SkipInstaller:(-not $BuildInstaller)

    $windowsBundle = Join-Path $windowsPath 'BShare-windows-x64'
    New-Item -ItemType Directory -Path $windowsBundle -Force | Out-Null
    Copy-Item -Path 'build\installer\windows\payload\*' -Destination $windowsBundle -Recurse -Force

    $zipPath = Join-Path $windowsPath "BShare-$safeVersion-windows-x64.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $windowsBundle '*') -DestinationPath $zipPath -Force
    $artifacts.Add("windows/BShare-windows-x64/")
    $artifacts.Add("windows/BShare-$safeVersion-windows-x64.zip")

    if ($BuildInstaller) {
        $setupName = "BShare-$version-windows-x64-setup.exe"
        $artifacts.Add("windows/$setupName")
        $artifacts.Add("windows/$setupName.sha256")
    }
}

$manifest = [ordered]@{
    app = 'BShare'
    version = $version
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    host = 'windows'
    artifacts = $artifacts
    notes = @(
        'This Windows script generates Android and Windows release artifacts.',
        'Linux and macOS releases require their native build scripts on native hosts.',
        'Google Play upload requires android/key.properties with a real upload key.'
    )
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $releasePath 'manifest.json') -Encoding UTF8

Write-Host "Release package ready: $releasePath"
