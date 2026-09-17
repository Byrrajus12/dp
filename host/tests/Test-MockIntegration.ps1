[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hostScript = Join-Path $PSScriptRoot '..\DesktopPetHost.ps1'
$mockScript = Join-Path $PSScriptRoot '..\..\bridge\MockPet.ps1'
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "desktop-pet-host-$PID"
$null = New-Item -ItemType Directory -Path $testDirectory
$hostOutput = Join-Path $testDirectory 'host.out.log'
$hostError = Join-Path $testDirectory 'host.err.log'
$pauseOutput = Join-Path $testDirectory 'mock-pause.out.log'
$pauseError = Join-Path $testDirectory 'mock-pause.err.log'
$playOutput = Join-Path $testDirectory 'mock-play.out.log'
$playError = Join-Path $testDirectory 'mock-play.err.log'

$portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([System.Net.IPEndPoint] $portProbe.LocalEndpoint).Port
$portProbe.Stop()

function Wait-LogMatch {
    param([string] $Path, [string] $Pattern, [int] $TimeoutSeconds = 12)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet)) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $content = if (Test-Path $Path) { Get-Content $Path -Raw } else { '(no log)' }
    throw "Timed out waiting for '$Pattern' in ${Path}:`n$content"
}

function Assert-LogAbsent {
    param([string] $Path, [string] $Pattern)
    if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet)) {
        throw "Unexpected '$Pattern' in ${Path}:`n$(Get-Content $Path -Raw)"
    }
}

function Start-Mock {
    param([string] $Action, [string] $OutputPath, [string] $ErrorPath)
    $message = [ordered]@{
        type = 'media.command'
        target = 'windows-media'
        data = [ordered]@{ action = $Action }
    } | ConvertTo-Json -Compress -Depth 4
    $messageBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message))
    return Start-Process powershell.exe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $ErrorPath `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mockScript, '-Port', $port, '-SendMessageBase64', $messageBase64)
}

function Stop-TestProcess {
    param([System.Diagnostics.Process] $Process)
    if ($null -ne $Process -and -not $Process.HasExited) {
        $Process.Kill()
        $Process.WaitForExit()
    }
}

$hostProcess = $null
$mock = $null
try {
    Write-Host "[test] using TCP port $port"
    $mock = Start-Mock -Action pause -OutputPath $pauseOutput -ErrorPath $pauseError
    Wait-LogMatch -Path $pauseOutput -Pattern 'listening on'

    $hostProcess = Start-Process powershell.exe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $hostOutput `
        -RedirectStandardError $hostError `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hostScript, '-PetHost', '127.0.0.1', '-Port', $port, '-InitialBackoffMilliseconds', 100, '-MaxBackoffMilliseconds', 400, '-PositionEmissionMilliseconds', 500)

    Wait-LogMatch -Path $pauseOutput -Pattern '"source":"desktop-pet-host"'
    Wait-LogMatch -Path $pauseOutput -Pattern '"type":"media.state"'
    Wait-LogMatch -Path $pauseOutput -Pattern '"action":"pause","accepted":true'
    Write-Host '[test] host -> mock state and mock -> host pause passed'

    Stop-TestProcess $mock
    $mock = $null
    Wait-LogMatch -Path $hostOutput -Pattern 'reconnecting in'

    $mock = Start-Mock -Action play -OutputPath $playOutput -ErrorPath $playError
    Wait-LogMatch -Path $playOutput -Pattern 'listening on'
    Wait-LogMatch -Path $playOutput -Pattern '"action":"play","accepted":true'
    Write-Host '[test] reconnect and mock -> host play passed'

    Start-Sleep -Milliseconds 300
    Assert-LogAbsent -Path $hostOutput -Pattern 'command.error'
    Assert-LogAbsent -Path $hostOutput -Pattern 'WARNING:'
    Assert-LogAbsent -Path $pauseOutput -Pattern 'command.error'
    Assert-LogAbsent -Path $playOutput -Pattern 'command.error'
    Write-Host '[test] informational pet events did not enter command routing'

    foreach ($errorPath in @($hostError, $pauseError, $playError)) {
        if ((Test-Path $errorPath) -and (Get-Item $errorPath).Length -gt 0) {
            throw "Process wrote to stderr (${errorPath}):`n$(Get-Content $errorPath -Raw)"
        }
    }
    Write-Host '[test] PASS'
}
finally {
    Stop-TestProcess $hostProcess
    Stop-TestProcess $mock
    Write-Host "[test] logs: $testDirectory"
}
