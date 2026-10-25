#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProgramPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-LocalSubnetScope($AddressFilter, $PortFilter) {
    # CIM/remoting may unwrap a one-element property into a string. Normalize
    # before indexing; indexing the original string reads only its first char.
    $remoteAddresses = @($AddressFilter.RemoteAddress)
    $localPorts = @($PortFilter.LocalPort)
    # NetSecurity also represents address keywords by their IPv4/IPv6 forms.
    # Accept only the full equivalent pair, never Any or an additional address.
    $localSubnet = ($remoteAddresses.Count -eq 1 -and $remoteAddresses[0] -eq 'LocalSubnet') -or
        ($remoteAddresses.Count -eq 2 -and $remoteAddresses -contains 'LocalSubnet4' -and $remoteAddresses -contains 'LocalSubnet6')
    if (-not $localSubnet) {
        throw "A firewall rule is not limited to the local subnet: $($remoteAddresses | ConvertTo-Json -Compress)."
    }
    if ($localPorts.Count -ne 1 -or $localPorts[0] -ne 'Any') {
        throw "BShare must support negotiated media ports and configurable HTTP ports: $($localPorts | ConvertTo-Json -Compress)."
    }
}

# Both CIM value shapes must satisfy the same strict scope, while public/extra
# addresses and restricted media ports must still fail verification.
Assert-LocalSubnetScope ([pscustomobject]@{ RemoteAddress = 'LocalSubnet' }) ([pscustomobject]@{ LocalPort = 'Any' })
Assert-LocalSubnetScope ([pscustomobject]@{ RemoteAddress = [string[]]@('LocalSubnet') }) ([pscustomobject]@{ LocalPort = [string[]]@('Any') })
Assert-LocalSubnetScope ([pscustomobject]@{ RemoteAddress = @('LocalSubnet4', 'LocalSubnet6') }) ([pscustomobject]@{ LocalPort = 'Any' })
foreach ($invalid in @(
    @{ RemoteAddress = 'Any'; LocalPort = 'Any' },
    @{ RemoteAddress = 'LocalSubnet4'; LocalPort = 'Any' },
    @{ RemoteAddress = @('LocalSubnet4', 'LocalSubnet6', '203.0.113.1'); LocalPort = 'Any' },
    @{ RemoteAddress = @('LocalSubnet', '203.0.113.1'); LocalPort = 'Any' },
    @{ RemoteAddress = 'LocalSubnet'; LocalPort = '53317' }
)) {
    $rejectedScope = $false
    try {
        Assert-LocalSubnetScope ([pscustomobject]$invalid) ([pscustomobject]$invalid)
    } catch {
        $rejectedScope = $true
    }
    if (-not $rejectedScope) { throw 'The firewall scope assertion accepted an invalid filter.' }
}

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
        $port = $rule | Get-NetFirewallPortFilter
        Write-Host ('Firewall filters: ' + ([ordered]@{
            rule = $rule.Name
            remoteAddress = @($address.RemoteAddress)
            localPort = @($port.LocalPort)
            protocol = $port.Protocol.ToString()
        } | ConvertTo-Json -Compress))
        Assert-LocalSubnetScope $address $port
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
