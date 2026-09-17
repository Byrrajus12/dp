[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\AdapterRegistry.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\adapters\WindowsMediaAdapter.psm1') -Force

function Assert-Equal {
    param($Actual, $Expected, [string] $Because)
    if ($Actual -ne $Expected) {
        throw "Expected '$Expected', got '$Actual': $Because"
    }
}

function Assert-True {
    param([bool] $Value, [string] $Because)
    if (-not $Value) { throw "Assertion failed: $Because" }
}

function New-FakeSession {
    param([string] $Id, [string] $Status)
    $session = [pscustomobject]@{
        SourceAppUserModelId = $Id
        Status = $Status
        Invocations = [System.Collections.Generic.List[string]]::new()
    }
    $session | Add-Member ScriptMethod GetPlaybackInfo { [pscustomobject]@{ PlaybackStatus = $this.Status } }
    $session | Add-Member ScriptMethod TryPlayAsync { $this.Invocations.Add('play'); $true }
    $session | Add-Member ScriptMethod TryPauseAsync { $this.Invocations.Add('pause'); $true }
    $session | Add-Member ScriptMethod TrySkipNextAsync { $this.Invocations.Add('next'); $true }
    $session | Add-Member ScriptMethod TrySkipPreviousAsync { $this.Invocations.Add('previous'); $true }
    return $session
}

$timeline = [pscustomobject]@{
    Position = [TimeSpan]::FromSeconds(10)
    StartTime = [TimeSpan]::Zero
    EndTime = [TimeSpan]::FromSeconds(60)
    LastUpdatedTime = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
}
$position = Get-EstimatedPositionMilliseconds `
    -Timeline $timeline `
    -Status playing `
    -PlaybackRate 1.5 `
    -Now ([DateTimeOffset]::Parse('2026-01-01T00:00:02Z'))
Assert-Equal $position 13000 'playing position should extrapolate from the timestamped anchor and rate'
Assert-Equal (Get-EstimatedPositionMilliseconds -Timeline $timeline -Status paused -Now ([DateTimeOffset]::Parse('2026-01-01T00:00:30Z'))) 10000 'paused position should stay at its anchor'
Assert-Equal (Get-EstimatedPositionMilliseconds -Timeline $timeline -Status playing -Now ([DateTimeOffset]::Parse('2026-01-01T00:02:00Z'))) 60000 'position should clamp to duration'
$offsetTimeline = [pscustomobject]@{
    Position = [TimeSpan]::FromSeconds(35)
    StartTime = [TimeSpan]::FromSeconds(30)
    EndTime = [TimeSpan]::FromSeconds(90)
    LastUpdatedTime = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
}
Assert-Equal (Get-EstimatedPositionMilliseconds -Timeline $offsetTimeline -Status paused) 5000 'position should be relative to a non-zero timeline start'
Write-Host '[test] position extrapolation passed'

$pausedA = New-FakeSession -Id 'app.a' -Status Paused
$playingB = New-FakeSession -Id 'app.b' -Status Playing
$playingC = New-FakeSession -Id 'app.c' -Status Playing
Assert-Equal (Select-WindowsMediaSession -Sessions @() -CurrentSession $null -SelectedSessionId $null) $null 'empty session list should produce no selection'
Assert-Equal (Select-WindowsMediaSession -Sessions @($pausedA, $playingB) -CurrentSession $pausedA -SelectedSessionId 'app.a').SourceAppUserModelId 'app.b' 'a playing session should replace a paused sticky selection'
Assert-Equal (Select-WindowsMediaSession -Sessions @($playingB, $playingC) -CurrentSession $playingC -SelectedSessionId 'app.b').SourceAppUserModelId 'app.b' 'a playing sticky selection should not switch unpredictably'
$pausedB = New-FakeSession -Id 'app.b' -Status Paused
Assert-Equal (Select-WindowsMediaSession -Sessions @($pausedA, $pausedB) -CurrentSession $pausedB -SelectedSessionId 'app.a').SourceAppUserModelId 'app.a' 'a paused sticky selection should remain selected when no session is playing'
Write-Host '[test] session selection passed'

$idle = New-WindowsMediaIdleState
Assert-Equal $idle.type 'media.state' 'no-session state should retain the normalized event type'
Assert-Equal $idle.data.status 'idle' 'no-session state should be semantic idle'
Assert-Equal $idle.data.sessionId $null 'no-session state should not invent a source identity'
Assert-Equal $idle.data.positionMs $null 'no-session state should not invent a position'
Write-Host '[test] no-session state passed'

$graceContext = @{
    LastPresentMediaState = $null
    MediaMissingSince = $null
    MediaLossGraceMilliseconds = 1500
}
$playingState = [pscustomobject]@{
    type = 'media.state'
    data = [pscustomobject]@{ sessionId = 'app.a'; status = 'playing'; title = 'Old track' }
}
$newPlayingState = [pscustomobject]@{
    type = 'media.state'
    data = [pscustomobject]@{ sessionId = 'app.b'; status = 'playing'; title = 'New track' }
}
$pausedState = [pscustomobject]@{
    type = 'media.state'
    data = [pscustomobject]@{ sessionId = 'app.a'; status = 'paused'; title = 'Old track' }
}
$graceStart = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $playingState -Now $graceStart) $playingState 'present media should pass through'
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $idle -Now $graceStart.AddMilliseconds(100)) $null 'brief media loss should be suppressed'
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $newPlayingState -Now $graceStart.AddMilliseconds(1500)) $newPlayingState 'replacement media inside grace should pass through directly'
Assert-Equal $graceContext.MediaMissingSince $null 'replacement media should cancel the pending idle'
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $pausedState -Now $graceStart.AddMilliseconds(1550)) $pausedState 'explicit paused state should never be delayed'
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $idle -Now $graceStart.AddMilliseconds(1600)) $null 'a new absence should begin a new grace window'
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $idle -Now $graceStart.AddMilliseconds(3099)) $null 'absence shorter than the grace should remain suppressed'
Assert-Equal (Resolve-WindowsMediaLossState -Context $graceContext -Message $idle -Now $graceStart.AddMilliseconds(3100)) $idle 'persistent absence should emit idle at the grace boundary'
$coldGraceContext = @{
    LastPresentMediaState = $null
    MediaMissingSince = $null
    MediaLossGraceMilliseconds = 1500
}
Assert-Equal (Resolve-WindowsMediaLossState -Context $coldGraceContext -Message $idle -Now $graceStart) $idle 'startup with no media should not wait'
Write-Host '[test] media-loss grace passed'

$registry = New-AdapterRegistry
$adapter = New-WindowsMediaAdapter
Assert-Equal $adapter.Context.MediaLossGraceMilliseconds 1500 'adapter should use the tested media-loss grace by default'
$commandSession = New-FakeSession -Id 'app.test' -Status Playing
$adapter.Context.SelectedSession = $commandSession
$adapter.Context.SelectedSessionId = 'app.test'
$adapter.Context.AwaitBoolean = { param($operation) [bool] $operation }
Register-HostAdapter -Registry $registry -Adapter $adapter
foreach ($action in @('play', 'pause', 'next', 'previous')) {
    $result = Invoke-HostMessageRoute -Registry $registry -Message ([pscustomobject]@{
        type = 'media.command'
        target = 'windows-media'
        data = [pscustomobject]@{ action = $action }
    })
    Assert-True $result.data.accepted "'$action' should return accepted=true"
    Assert-Equal $result.data.action $action "'$action' should be preserved in the result"
}
Assert-Equal ($commandSession.Invocations -join ',') 'play,pause,next,previous' 'every explicit command should call its matching session method'
Write-Host '[test] routing and command mapping passed'

$unrouted = Invoke-HostMessageRoute -Registry $registry -Message ([pscustomobject]@{
    type = 'pet.received'
    data = [pscustomobject]@{ receivedType = 'media.state' }
})
Assert-Equal $unrouted $null 'informational messages without a target should not enter command routing'

try {
    $null = Invoke-HostMessageRoute -Registry $registry -Message ([pscustomobject]@{
        type = 'media.command'
        target = 'missing-adapter'
        data = [pscustomobject]@{ action = 'pause' }
    })
    throw 'Expected missing target routing to fail.'
}
catch {
    Assert-True ($_.Exception.Message -like "*No adapter is registered*") 'unknown targets should fail at the generic routing boundary'
}

Write-Host '[test] PASS'
