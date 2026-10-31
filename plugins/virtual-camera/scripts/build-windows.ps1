[CmdletBinding()]
param(
    [string]$BuildDirectory = '.dart_tool/virtual-camera/build',
    [string]$OutputDirectory = 'dist/virtual-camera/windows',
    [string]$CMakeExecutable = '',
    [switch]$BuildTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Repository-Path([string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $repositoryPath $Value))
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$instances = @(& $vswhere -all -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json)
$instance = $instances | Sort-Object { [version]$_.installationVersion } -Descending | Select-Object -First 1
if (-not $instance) { throw 'Visual Studio C++ Build Tools is required.' }
if (-not $CMakeExecutable) { $CMakeExecutable = Join-Path $instance.installationPath 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe' }
$generator = switch (([version]$instance.installationVersion).Major) { 17 { 'Visual Studio 17 2022' } 18 { 'Visual Studio 18 2026' } default { throw 'Unsupported Visual Studio generator.' } }
$buildPath = Repository-Path $BuildDirectory
$outputPath = Repository-Path $OutputDirectory
$tests = if ($BuildTests) { 'ON' } else { 'OFF' }
& $CMakeExecutable -S (Repository-Path 'plugins/virtual-camera') -B $buildPath -G $generator -A x64 "-DBSHARE_VIRTUAL_CAMERA_TESTS=$tests"
if ($LASTEXITCODE -ne 0) { throw 'Virtual camera configure failed.' }
& $CMakeExecutable --build $buildPath --config Release --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Virtual camera build failed.' }
if ($BuildTests) {
    & (Join-Path (Split-Path $CMakeExecutable) 'ctest.exe') --test-dir $buildPath -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Virtual camera checks failed.' }
}
& $CMakeExecutable --install $buildPath --config Release --prefix $outputPath
if ($LASTEXITCODE -ne 0) { throw 'Virtual camera staging failed.' }
Write-Output "Staged virtual camera: $outputPath"
