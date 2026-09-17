[CmdletBinding()]
param(
    [Parameter()]
    [Alias('Host')]
    [string] $PetHost = '127.0.0.1',

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 8765,

    [Parameter()]
    [ValidateRange(128, 1048576)]
    [int] $MaxMessageBytes = 8192,

    [Parameter()]
    [ValidateRange(50, 60000)]
    [int] $InitialBackoffMilliseconds = 250,

    [Parameter()]
    [ValidateRange(50, 60000)]
    [int] $MaxBackoffMilliseconds = 5000,

    [Parameter()]
    [ValidateRange(100, 60000)]
    [int] $PositionEmissionMilliseconds = 5000,

    [Parameter()]
    [ValidateRange(0, 5000)]
    [int] $MediaLossGraceMilliseconds = 1500,

    [Parameter()]
    [switch] $NoPet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'DesktopPetHost requires Windows PowerShell 5.1 for native WinRT/GSMTC access. Run it with powershell.exe, not pwsh.'
}
if ($InitialBackoffMilliseconds -gt $MaxBackoffMilliseconds) {
    throw 'InitialBackoffMilliseconds cannot exceed MaxBackoffMilliseconds.'
}

Import-Module (Join-Path $PSScriptRoot 'AdapterRegistry.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PetTransport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'adapters\WindowsMediaAdapter.psm1') -Force

function Write-HostLog {
    param([string] $Message)
    Write-Host "[host] $Message"
    [Console]::Out.Flush()
}

$registry = New-AdapterRegistry
Register-HostAdapter -Registry $registry -Adapter (
    New-WindowsMediaAdapter `
        -PositionEmissionMilliseconds $PositionEmissionMilliseconds `
        -MediaLossGraceMilliseconds $MediaLossGraceMilliseconds
)
$transport = $null

try {
    foreach ($name in @($registry.Keys | Sort-Object)) {
        $adapter = $registry[$name]
        & $adapter.Start $adapter.Context
    }
    Write-HostLog "started adapters: $(@($registry.Keys | Sort-Object) -join ', ')"

    if (-not $NoPet) {
        $transport = New-PetTransport `
            -HostName $PetHost `
            -Port $Port `
            -MaxMessageBytes $MaxMessageBytes `
            -InitialBackoffMilliseconds $InitialBackoffMilliseconds `
            -MaxBackoffMilliseconds $MaxBackoffMilliseconds
        Write-HostLog "pet target is ${PetHost}:$Port"
    }
    else {
        Write-HostLog 'pet transport disabled'
    }

    Write-HostLog 'press Ctrl+C to stop'
    while ($true) {
        $now = [DateTimeOffset]::Now
        foreach ($name in @($registry.Keys | Sort-Object)) {
            $adapter = $registry[$name]
            foreach ($message in @(& $adapter.Poll $adapter.Context $now)) {
                if ($null -eq $message) { continue }
                $json = $message | ConvertTo-Json -Compress -Depth 10
                Write-HostLog "event: $json"
                if ($null -ne $transport) {
                    Send-PetMessage -Transport $transport -Message $message
                }
            }
        }

        if ($null -ne $transport) {
            foreach ($incoming in @(Update-PetTransport -Transport $transport -Now $now)) {
                try {
                    $response = Invoke-HostMessageRoute -Registry $registry -Message $incoming
                    if ($null -ne $response) {
                        Send-PetMessage -Transport $transport -Message $response
                    }
                }
                catch {
                    $incomingTypeProperty = $incoming.PSObject.Properties['type']
                    $incomingType = if ($null -eq $incomingTypeProperty) { $null } else { [string] $incomingTypeProperty.Value }
                    $errorResponse = [ordered]@{
                        type = 'command.error'
                        source = 'desktop-pet-host'
                        data = [ordered]@{
                            commandType = $incomingType
                            message = $_.Exception.GetBaseException().Message
                        }
                    }
                    Write-Warning "[host] command rejected: $($errorResponse.data.message)"
                    Send-PetMessage -Transport $transport -Message $errorResponse
                }
            }
        }
        Start-Sleep -Milliseconds 50
    }
}
finally {
    if ($null -ne $transport) { Stop-PetTransport -Transport $transport }
    foreach ($name in @($registry.Keys | Sort-Object -Descending)) {
        $adapter = $registry[$name]
        try { & $adapter.Stop $adapter.Context }
        catch { Write-Warning "[host] adapter '$name' failed to stop: $($_.Exception.GetBaseException().Message)" }
    }
    Write-HostLog 'stopped'
}
