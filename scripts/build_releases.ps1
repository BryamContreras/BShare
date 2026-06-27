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
$releaseRoot = "dist\releases\BShare-$safeVersion"
Reset-Directory $releaseRoot

$releasePath = Join-Path $root $releaseRoot
$androidPath = Join-Path $releasePath 'android'
$windowsPath = Join-Path $releasePath 'windows'
$installerPath = Join-Path $releasePath 'installers\windows'
$linuxPath = Join-Path $releasePath 'linux'
$macosPath = Join-Path $releasePath 'macos'
New-Item -ItemType Directory -Path $androidPath, $windowsPath, $installerPath, $linuxPath, $macosPath -Force | Out-Null

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
    flutter build windows --release

    $windowsBundle = Join-Path $windowsPath 'BShare-windows-x64'
    New-Item -ItemType Directory -Path $windowsBundle -Force | Out-Null
    Copy-Item -Path 'build\windows\x64\runner\Release\*' -Destination $windowsBundle -Recurse -Force

    $zipPath = Join-Path $windowsPath "BShare-$safeVersion-windows-x64.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $windowsBundle '*') -DestinationPath $zipPath -Force
    $artifacts.Add("windows/BShare-windows-x64/")
    $artifacts.Add("windows/BShare-$safeVersion-windows-x64.zip")

    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    }
    if ($BuildInstaller -and -not $iscc) {
        throw 'Inno Setup compiler was not found. Install Inno Setup or remove -BuildInstaller.'
    }
    if ($iscc) {
        & $iscc.Source "/DMyAppVersion=$($version.Split('+')[0])" 'installer\windows\BShare.iss'
        $setup = Get-ChildItem -Path 'dist\installers\windows' -Filter 'BShare-Setup-*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($setup) {
            Copy-Item -LiteralPath $setup.FullName -Destination $installerPath -Force
            $artifacts.Add("installers/windows/$($setup.Name)")
        }
    }
}

Set-Content -Path (Join-Path $linuxPath 'BUILD_ON_LINUX.txt') -Value @"
Linux desktop releases must be built on Linux:

  ./scripts/build_releases.sh --linux-only

The generated bundle will be copied into this release structure by that script.
"@

Set-Content -Path (Join-Path $macosPath 'BUILD_ON_MACOS.txt') -Value @"
macOS releases must be built on macOS:

  ./scripts/build_releases.sh --macos-only

The generated .app zip will be copied into this release structure by that script.
"@

$manifest = [ordered]@{
    app = 'BShare'
    version = $version
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    host = 'windows'
    artifacts = $artifacts
    notes = @(
        'Linux and macOS releases require native hosts.',
        'Google Play upload requires android/key.properties with a real upload key.'
    )
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $releasePath 'manifest.json') -Encoding UTF8

Write-Host "Release package ready: $releasePath"
