[CmdletBinding()]
param(
    [string]$BuildDirectory = 'build/windows/x64/runner/Release',
    [string]$OutputDirectory = 'dist/windows',
    [string]$Version = '',
    [string]$BuildNumber = '',
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$buildPath = Join-Path $repository $BuildDirectory
$outputPath = Join-Path $repository $OutputDirectory
$stagingPath = Join-Path $repository 'build/installer/windows/payload'

$pubspec = Get-Content -LiteralPath (Join-Path $repository 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) {
    throw 'pubspec.yaml must contain version: major.minor.patch+build.'
}
$pubspecVersion = $versionMatch.Value.Trim() -replace '^version:\s*', ''
if (-not $Version) { $Version = $pubspecVersion.Split('+')[0] }
if (-not $BuildNumber) { $BuildNumber = $pubspecVersion.Split('+')[1] }
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $BuildNumber -notmatch '^\d+$') {
    throw 'Version must be major.minor.patch, and BuildNumber must be a nonnegative integer.'
}
$fullVersion = "$Version+$BuildNumber"
$fileVersion = "$Version.$BuildNumber"
foreach ($part in $fileVersion.Split('.')) {
    if ([long]$part -gt 65535) {
        throw "Windows version components must be at most 65535: $fileVersion"
    }
}

foreach ($required in @('BShare.exe', 'flutter_windows.dll', 'flutter_webrtc_plugin.dll', 'libwebrtc.dll', 'data/icudtl.dat', 'data/app.so', 'data/flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $buildPath $required))) {
        throw "Windows release payload is incomplete: $required"
    }
}

if (Test-Path -LiteralPath $stagingPath) {
    Remove-Item -LiteralPath $stagingPath -Recurse -Force
}
New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null
New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $buildPath '*') -Destination $stagingPath -Recurse -Force
Get-ChildItem -LiteralPath $stagingPath -Filter '*.pdb' -File -Recurse | Remove-Item -Force
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE') -Destination (Join-Path $stagingPath 'LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'configure-firewall.ps1') -Destination $stagingPath

# Use the redistributable files licensed for app-local deployment, not copies
# from System32. This keeps installation per-user without a second installer.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio vswhere.exe was not found.'
}
$visualStudio = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $visualStudio) {
    throw 'Visual Studio 2022 with C++ tools was not found.'
}
$redistributableRoot = Join-Path $visualStudio.Trim() 'VC/Redist/MSVC'
$runtimeDirectory = Get-ChildItem -LiteralPath $redistributableRoot -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $runtimeDirectory) {
    throw "The Visual Studio 2022 x64 redistributable CRT was not found in $redistributableRoot."
}
Copy-Item -Path (Join-Path $runtimeDirectory '*.dll') -Destination $stagingPath -Force
foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stagingPath $runtime))) {
        throw "The app-local C++ runtime is incomplete: $runtime"
    }
}
Write-Host "Bundled Microsoft CRT from $runtimeDirectory"

if ($SkipInstaller) {
    Write-Host "Staged Windows payload at $stagingPath"
    return
}

$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'Inno Setup 6 was not found. Install it before packaging.'
}
$firewallSource = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'configure-firewall.ps1'))
$firewallBase64 = [Convert]::ToBase64String($firewallSource)
# Installer/uninstaller execute a compiled-in payload, never a mutable script
# from LocalAppData. Reserve room for runtime path/arguments in Windows' limit.
if ($firewallBase64.Length -gt 24000) {
    throw 'Embedded firewall helper exceeds the safe Windows command-line size.'
}
$compilerArguments = @(
    "/DAppVersion=$Version",
    "/DAppFileVersion=$fileVersion",
    "/DAppFullVersion=$fullVersion",
    "/DAppSourceDir=$stagingPath",
    "/DAppOutputDir=$outputPath",
    "/DFirewallScriptBase64=$firewallBase64",
    (Join-Path $repository 'installer/windows/BShare.iss')
)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}
$installerPath = Join-Path $outputPath "BShare-$fullVersion-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "Inno Setup did not generate $installerPath."
}
$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([System.IO.Path]::GetFileName($installerPath))" |
    Set-Content -LiteralPath "$installerPath.sha256" -Encoding utf8NoBOM
Write-Host "Created $installerPath"
