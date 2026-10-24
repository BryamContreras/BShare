#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProgramPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$configure = Join-Path ([System.IO.Path]::GetDirectoryName($ProgramPath)) 'configure-firewall.ps1'
$marker = Join-Path ([System.IO.Path]::GetDirectoryName($ProgramPath)) 'bshare-firewall.json'
$unrelatedName = "BShare-firewall-verification-$([guid]::NewGuid())"
$blockName = "BShare-firewall-block-verification-$([guid]::NewGuid())"
$publicBlockName = "BShare-firewall-public-verification-$([guid]::NewGuid())"
$names = @()
try {
    # Cleanup must leave every other application/installation rule untouched.
    New-NetFirewallRule -Name $unrelatedName -DisplayName $unrelatedName -Direction Inbound -Action Block -Profile Private -Program "$ProgramPath.unrelated" | Out-Null
    # A denied Public profile must not prevent a separate Private LAN opt-in.
    New-NetFirewallRule -Name $publicBlockName -DisplayName $publicBlockName -Direction Inbound -Action Block -Profile Public -Program $ProgramPath | Out-Null
    $configuration = & $configure -Mode Add -ProgramPath $ProgramPath
    $names = @($configuration.rules)
    if ($names.Count -ne 2) { throw 'Expected one TCP and one UDP firewall rule.' }
    & $configure -Mode Add -ProgramPath $ProgramPath | Out-Null
    if (Test-Path -LiteralPath $marker) { throw 'The elevated helper must not write into the user installation directory.' }
    $rules = @(Get-NetFirewallRule -Name $names)
    if ($rules.Count -ne 2) { throw 'Repeated network setup created duplicate rules.' }
    $protocols = @()
    foreach ($rule in $rules) {
        if ($rule.Profile.ToString() -ne 'Private' -or $rule.Direction.ToString() -ne 'Inbound' -or $rule.Action.ToString() -ne 'Allow' -or $rule.Enabled.ToString() -ne 'True') {
            throw 'A firewall rule has the wrong profile, direction, action or enabled state.'
        }
        $application = $rule | Get-NetFirewallApplicationFilter
        if ($application.Program -ine $ProgramPath) { throw 'A firewall rule permits another executable.' }
        $address = $rule | Get-NetFirewallAddressFilter
        if (@($address.RemoteAddress).Count -ne 1 -or $address.RemoteAddress[0] -ne 'LocalSubnet') {
            throw 'A firewall rule is not limited to the local subnet.'
        }
        $port = $rule | Get-NetFirewallPortFilter
        if (@($port.LocalPort).Count -ne 1 -or $port.LocalPort[0] -ne 'Any') {
            throw 'BShare must support negotiated media ports and configurable HTTP ports.'
        }
        $protocols += $port.Protocol.ToString()
    }
    # Windows versions may expose the protocols as names or IANA numbers.
    if (-not (($protocols -contains 'TCP' -or $protocols -contains '6') -and ($protocols -contains 'UDP' -or $protocols -contains '17'))) {
        throw 'Firewall configuration did not cover both TCP signaling and UDP media/discovery.'
    }
    & $configure -Mode Remove -ProgramPath $ProgramPath
    & $configure -Mode Remove -ProgramPath $ProgramPath
    if (@(Get-NetFirewallRule -Name $names -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'Network cleanup left its firewall rules behind.'
    }
    if ($null -eq (Get-NetFirewallRule -Name $unrelatedName)) { throw 'Cleanup removed an unrelated rule.' }
    if ($null -eq (Get-NetFirewallRule -Name $publicBlockName)) { throw 'Setup or cleanup removed the Public profile restriction.' }

    # Previously denying Windows' firewall prompt creates an explicit Block rule.
    # Report that conflict and retain the user's decision instead of claiming
    # that an Allow rule overrides it.
    New-NetFirewallRule -Name $blockName -DisplayName $blockName -Direction Inbound -Action Block -Profile Private -Program $ProgramPath | Out-Null
    $rejected = $false
    try {
        & $configure -Mode Add -ProgramPath $ProgramPath
    } catch {
        $rejected = $_.Exception.Message -match 'explicit inbound Block rule'
    }
    if (-not $rejected) { throw 'An existing explicit Block rule was not reported.' }
    if ($null -eq (Get-NetFirewallRule -Name $blockName)) { throw 'Network setup removed an existing restriction.' }
    Write-Host 'Verified scoped LAN firewall access, idempotence, cleanup and preservation of existing restrictions.'
} finally {
    & $configure -Mode Remove -ProgramPath $ProgramPath
    Get-NetFirewallRule -Name @($unrelatedName, $blockName, $publicBlockName) -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
