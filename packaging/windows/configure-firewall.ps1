#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Add', 'Remove')][string]$Mode = 'Add',
    [Parameter(Mandatory = $true)][string]$ProgramPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Do not auto-load a same-named module from the user's writable PSModulePath
# after elevation. Use Windows' own NetSecurity manifest explicitly.
Import-Module -Name ([System.Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules\NetSecurity\NetSecurity.psd1') -Force
$program = [System.IO.Path]::GetFullPath($ProgramPath)
if ([System.IO.Path]::GetFileName($program) -ine 'BShare.exe') {
    throw 'Firewall configuration is limited to the installed BShare.exe.'
}
if ($Mode -eq 'Add' -and -not [System.IO.File]::Exists($program)) {
    throw "BShare.exe does not exist: $program"
}
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($program.ToLowerInvariant()))
    $installation = ([System.BitConverter]::ToString($digest) -replace '-', '').Substring(0, 24)
} finally {
    $sha.Dispose()
}
$ruleNames = @("BShare-LAN-$installation-TCP", "BShare-LAN-$installation-UDP")
$created = @()
try {
    if ($Mode -eq 'Remove') {
        foreach ($name in $ruleNames) {
            Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        }
        Write-Host 'Removed the LAN firewall rules for this BShare installation.'
        return
    }

    # An explicit Block rule for Private/Any wins over our Private Allow rule.
    # A Public-only block must remain intact but does not conflict here.
    # Do not silently
    # delete rules belonging to Windows, administrators or another application.
    $blocked = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
        Where-Object { $_.Profile.ToString() -match '(^|,\s*)(Any|Private)($|,)' } |
        Get-NetFirewallApplicationFilter |
        Where-Object { [Environment]::ExpandEnvironmentVariables($_.Program) -ieq $program })
    if ($blocked.Count -gt 0) {
        throw 'Windows already has an explicit inbound Block rule for BShare on private networks. Review that rule in Windows Defender Firewall before configuring LAN access. Existing restrictions were preserved.'
    }

    foreach ($protocol in @('TCP', 'UDP')) {
        $name = "BShare-LAN-$installation-$protocol"
        $parameters = @{
            Name = $name
            DisplayName = "BShare LAN ($protocol)"
            Description = 'BShare local transfers and screen/camera streaming. Private networks and local subnet only.'
            Direction = 'Inbound'
            Action = 'Allow'
            Enabled = 'True'
            Profile = 'Private'
            Program = $program
            Protocol = $protocol
            LocalPort = 'Any'
            RemoteAddress = 'LocalSubnet'
            EdgeTraversalPolicy = 'Block'
        }
        $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            New-NetFirewallRule @parameters | Out-Null
            $created += $name
        } else {
            $parameters.Remove('DisplayName')
            $parameters.NewDisplayName = "BShare LAN ($protocol)"
            Set-NetFirewallRule @parameters | Out-Null
        }
    }
    # Do not write logs/markers from this elevated process into the user's
    # writable directory. The non-elevated installer records its own state.
    [pscustomobject]@{ program = $program; rules = $ruleNames }
    Write-Host 'BShare can receive TCP and UDP on private local networks. The application itself does not run as administrator.'
} catch {
    foreach ($name in $created) {
        Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
    throw
}
