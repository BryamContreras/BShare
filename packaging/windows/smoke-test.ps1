[CmdletBinding()]
param([string]$OutputDirectory = 'dist/windows')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$outputPath = Join-Path $repository $OutputDirectory
$verificationPath = Join-Path $outputPath 'verification'
New-Item -Path $verificationPath -ItemType Directory -Force | Out-Null
$installers = @(Get-ChildItem -LiteralPath $outputPath -Filter '*-windows-x64-setup.exe' -File)
if ($installers.Count -ne 1) {
    throw "Expected one Windows installer, found $($installers.Count)."
}
$installPath = Join-Path ([System.IO.Path]::GetTempPath()) "bshare-installer-check-$([guid]::NewGuid())"
# A stable AppId makes normal upgrades work. Do not let a local smoke test
# upgrade and uninstall an existing installation belonging to its operator.
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B7BB9A02-7C54-4DD3-A239-3FA13514A93F}_is1'
foreach ($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryHive]::LocalMachine)) {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
        try {
            $existing = $registry.OpenSubKey($uninstallKey)
            if ($null -ne $existing) {
                $existing.Dispose()
                throw 'BShare is already installed. Run the installer smoke test on a clean Windows runner.'
            }
        } finally {
            $registry.Dispose()
        }
    }
}
$installLog = Join-Path $verificationPath 'install.log'
$uninstallLog = Join-Path $verificationPath 'uninstall.log'
$application = $null
$uninstalled = $false
try {
    $installArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=', "/DIR=`"$installPath`"", "/LOG=`"$installLog`"")
    $installer = Start-Process -FilePath $installers[0].FullName -ArgumentList $installArguments -PassThru -Wait
    if ($installer.ExitCode -ne 0) {
        throw "Silent installation failed with exit code $($installer.ExitCode)."
    }

    $payload = Join-Path $repository 'build/installer/windows/payload'
    $files = @(Get-ChildItem -LiteralPath $payload -File -Recurse)
    foreach ($source in $files) {
        $relative = [System.IO.Path]::GetRelativePath($payload, $source.FullName)
        $installed = Join-Path $installPath $relative
        if (-not (Test-Path -LiteralPath $installed)) {
            throw "Installed payload is missing $relative."
        }
        if ((Get-FileHash -LiteralPath $source.FullName).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) {
            throw "Installed payload differs from staged file $relative."
        }
    }

    $application = Start-Process -FilePath (Join-Path $installPath 'BShare.exe') -WorkingDirectory $installPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $application.Refresh()
        if ($application.HasExited) {
            throw "Installed BShare exited during startup with code $($application.ExitCode)."
        }
    } while ($application.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($application.MainWindowHandle -eq 0) {
        throw 'Installed BShare did not create its main window within 30 seconds.'
    }
    Start-Sleep -Seconds 3
    $application.Refresh()
    if ($application.HasExited) {
        throw "Installed BShare exited unexpectedly with code $($application.ExitCode)."
    }
    if (-not $application.CloseMainWindow() -or -not $application.WaitForExit(15000)) {
        throw 'Installed BShare did not close after its main window received a close request.'
    }
    if ($application.ExitCode -ne 0) {
        throw "Installed BShare closed with exit code $($application.ExitCode)."
    }

    $uninstallerPath = Join-Path $installPath 'unins000.exe'
    $uninstallArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$uninstallLog`"")
    $uninstaller = Start-Process -FilePath $uninstallerPath -ArgumentList $uninstallArguments -PassThru -Wait
    if ($uninstaller.ExitCode -ne 0) {
        throw "Silent uninstall failed with exit code $($uninstaller.ExitCode)."
    }
    $uninstalled = $true
    if (Test-Path -LiteralPath (Join-Path $installPath 'BShare.exe')) {
        throw 'The uninstaller left the application executable behind.'
    }
    [ordered]@{
        installer = $installers[0].Name
        filesVerified = $files.Count
        installed = $true
        launched = $true
        mainWindowCreated = $true
        applicationExitCode = $application.ExitCode
        uninstalled = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $verificationPath 'result.json') -Encoding utf8NoBOM
} finally {
    # Only stop the exact process created by this smoke test if normal closing
    # failed. Never target other instances by application name.
    if ($null -ne $application -and -not $application.HasExited) {
        Stop-Process -Id $application.Id -Force
        $application.WaitForExit()
    }
    $uninstallerPath = Join-Path $installPath 'unins000.exe'
    if (-not $uninstalled -and (Test-Path -LiteralPath $uninstallerPath)) {
        $cleanup = Start-Process -FilePath $uninstallerPath -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -PassThru -Wait
        if ($cleanup.ExitCode -ne 0) {
            Write-Warning "Installer test cleanup returned $($cleanup.ExitCode)."
        }
    }
    if (Test-Path -LiteralPath $installPath) {
        Remove-Item -LiteralPath $installPath -Recurse -Force
    }
}
