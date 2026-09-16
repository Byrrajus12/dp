[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bridgeScript = Join-Path $PSScriptRoot 'DesktopPetBridge.ps1'
$mockScript = Join-Path $PSScriptRoot 'MockPet.ps1'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "desktop-pet-bridge-$PID"
$null = New-Item -ItemType Directory -Path $testDirectory
$bridgeOutput = Join-Path $testDirectory 'bridge.out.log'
$bridgeError = Join-Path $testDirectory 'bridge.err.log'
$mockOutput = Join-Path $testDirectory 'mock.out.log'
$mockError = Join-Path $testDirectory 'mock.err.log'
$mockRestartOutput = Join-Path $testDirectory 'mock-restart.out.log'
$mockRestartError = Join-Path $testDirectory 'mock-restart.err.log'

$portProbe = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    0
)
$portProbe.Start()
$port = ([System.Net.IPEndPoint] $portProbe.LocalEndpoint).Port
$portProbe.Stop()

function Start-MockPet {
    param(
        [string] $OutputPath,
        [string] $ErrorPath
    )

    Start-Process pwsh -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $ErrorPath `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-File', $mockScript,
            '-Port', $port
        )
}

function Wait-LogMatch {
    param(
        [string] $Path,
        [string] $Pattern,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet)) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $content = if (Test-Path $Path) { Get-Content $Path -Raw } else { '(no log)' }
    throw "Timed out waiting for '$Pattern' in ${Path}:`n$content"
}

function Assert-LogCount {
    param(
        [string] $Path,
        [string] $Pattern,
        [int] $ExpectedCount
    )

    $actualCount = if (Test-Path $Path) {
        @(Select-String -Path $Path -Pattern $Pattern).Count
    }
    else {
        0
    }

    if ($actualCount -ne $ExpectedCount) {
        $content = if (Test-Path $Path) { Get-Content $Path -Raw } else { '(no log)' }
        throw "Expected $ExpectedCount matches for '$Pattern' in ${Path}, found ${actualCount}:`n$content"
    }
}

function Stop-TestProcess {
    param([System.Diagnostics.Process] $Process)

    if ($null -ne $Process -and -not $Process.HasExited) {
        $Process.Kill($true)
        $Process.WaitForExit()
    }
}

$mock = $null
$bridge = $null

try {
    Write-Host "[test] using TCP port $port"
    $mock = Start-MockPet -OutputPath $mockOutput -ErrorPath $mockError
    Wait-LogMatch -Path $mockOutput -Pattern 'listening on'

    $bridge = Start-Process pwsh -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $bridgeOutput `
        -RedirectStandardError $bridgeError `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-File', $bridgeScript,
            '-PetHost', '127.0.0.1', '-Port', $port,
            '-SendApprovalRequested',
            '-InitialBackoffMilliseconds', 100,
            '-MaxBackoffMilliseconds', 400
        )

    Wait-LogMatch -Path $mockOutput -Pattern '"type":"system.hello"'
    Wait-LogMatch -Path $mockOutput -Pattern '"type":"approval.requested"'
    Wait-LogMatch -Path $bridgeOutput -Pattern 'receivedType":"system.hello"'
    Wait-LogMatch -Path $bridgeOutput -Pattern 'receivedType":"approval.requested"'
    Assert-LogCount -Path $mockOutput -Pattern '"type":"system.hello"' -ExpectedCount 1
    Assert-LogCount -Path $mockOutput -Pattern '"type":"approval.requested"' -ExpectedCount 1
    Write-Host '[test] bidirectional NDJSON passed'

    Stop-TestProcess -Process $mock
    $mock = $null
    Wait-LogMatch -Path $bridgeOutput -Pattern 'disconnected: Pet closed the connection.'
    Wait-LogMatch -Path $bridgeOutput -Pattern 'reconnecting in'
    Write-Host '[test] mock server killed; bridge entered reconnect loop'

    $mock = Start-MockPet -OutputPath $mockRestartOutput -ErrorPath $mockRestartError
    Wait-LogMatch -Path $mockRestartOutput -Pattern 'listening on'
    Wait-LogMatch -Path $mockRestartOutput -Pattern '"type":"system.hello"'
    Assert-LogCount -Path $mockRestartOutput -Pattern '"type":"system.hello"' -ExpectedCount 1
    Assert-LogCount -Path $mockRestartOutput -Pattern '"type":"approval.requested"' -ExpectedCount 0
    Write-Host '[test] mock server restarted; bridge reconnected and sent a new hello'

    if ((Test-Path $bridgeError) -and (Get-Item $bridgeError).Length -gt 0) {
        throw "Bridge wrote to stderr:`n$(Get-Content $bridgeError -Raw)"
    }
    if ((Test-Path $mockError) -and (Get-Item $mockError).Length -gt 0) {
        throw "Mock wrote to stderr:`n$(Get-Content $mockError -Raw)"
    }
    if ((Test-Path $mockRestartError) -and (Get-Item $mockRestartError).Length -gt 0) {
        throw "Restarted mock wrote to stderr:`n$(Get-Content $mockRestartError -Raw)"
    }

    Write-Host '[test] PASS'
}
finally {
    Stop-TestProcess -Process $bridge
    Stop-TestProcess -Process $mock
    Write-Host "[test] logs: $testDirectory"
}
