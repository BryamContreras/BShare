[CmdletBinding()]
param(
    [string]$BinaryDirectory = '.dart_tool/virtual-camera/build/Release',
    [string]$PackageDirectory = 'dist/virtual-camera/packages',
    [string]$InnoSetupCompiler = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Repository-Path([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryPath $Value))
}
$binaryPath = Repository-Path $BinaryDirectory
$packagePath = Repository-Path $PackageDirectory
foreach ($name in @('bshare-camera.exe', 'bshare-virtual-camera.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $binaryPath $name) -PathType Leaf)) { throw "Missing $name. Build the camera first." }
}
if (-not $InnoSetupCompiler) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe')
    )
    $InnoSetupCompiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $InnoSetupCompiler) { throw 'Inno Setup 6 is required to package the component.' }
New-Item -ItemType Directory -Force -Path $packagePath | Out-Null
& $InnoSetupCompiler "/DBinaryDirectory=$binaryPath" "/DPackageDirectory=$packagePath" (Join-Path $PSScriptRoot 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Virtual camera installer compilation failed.' }
$installerPath = Join-Path $packagePath 'bshare-virtual-camera-0.1.0-windows-x64-setup.exe'
$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$installerPath.sha256", "$hash  $([IO.Path]::GetFileName($installerPath))`n")
Write-Output "Installer: $installerPath"
