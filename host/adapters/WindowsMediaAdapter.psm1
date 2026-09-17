Set-StrictMode -Version Latest

function Get-WinRtResult {
    param(
        [Parameter(Mandatory = $true)] $Operation,
        [Parameter(Mandatory = $true)][type] $ResultType
    )

    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1
    $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-WinRtBooleanResult {
    param([Parameter(Mandatory = $true)] $Operation)
    return [bool] (Get-WinRtResult -Operation $Operation -ResultType ([bool]))
}

function Convert-PlaybackStatus {
    param($Status)

    switch ([string] $Status) {
        'Playing' { return 'playing' }
        'Paused' { return 'paused' }
        default { return 'idle' }
    }
}

function Get-EstimatedPositionMilliseconds {
    param(
        [Parameter(Mandatory = $true)] $Timeline,
        [Parameter(Mandatory = $true)][string] $Status,
        [double] $PlaybackRate = 1.0,
        [datetimeoffset] $Now = [DateTimeOffset]::Now
    )

    $positionMs = [double] $Timeline.Position.TotalMilliseconds
    if ($Status -eq 'playing') {
        $elapsedMs = ($Now - [DateTimeOffset] $Timeline.LastUpdatedTime).TotalMilliseconds
        if ($elapsedMs -gt 0) {
            $positionMs += $elapsedMs * $PlaybackRate
        }
    }

    $startMs = [double] $Timeline.StartTime.TotalMilliseconds
    $endMs = [double] $Timeline.EndTime.TotalMilliseconds
    if ($positionMs -lt $startMs) { $positionMs = $startMs }
    if ($endMs -gt $startMs -and $positionMs -gt $endMs) { $positionMs = $endMs }
    return [long] [Math]::Round($positionMs - $startMs)
}

function Select-WindowsMediaSession {
    param(
        [object[]] $Sessions,
        $CurrentSession,
        [string] $SelectedSessionId
    )

    if ($Sessions.Count -eq 0) { return $null }

    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($SelectedSessionId)) {
        $selected = $Sessions |
            Where-Object { $_.SourceAppUserModelId -eq $SelectedSessionId } |
            Select-Object -First 1
    }
    if ($null -ne $selected -and
        [string] $selected.GetPlaybackInfo().PlaybackStatus -eq 'Playing') {
        return $selected
    }

    $currentIsPlaying = $null -ne $CurrentSession -and
        [string] $CurrentSession.GetPlaybackInfo().PlaybackStatus -eq 'Playing'
    if ($currentIsPlaying) { return $CurrentSession }

    $playing = $Sessions |
        Where-Object { [string] $_.GetPlaybackInfo().PlaybackStatus -eq 'Playing' } |
        Sort-Object SourceAppUserModelId |
        Select-Object -First 1
    if ($null -ne $playing) { return $playing }
    if ($null -ne $selected) { return $selected }
    if ($null -ne $CurrentSession) { return $CurrentSession }
    return $Sessions | Sort-Object SourceAppUserModelId | Select-Object -First 1
}

function Get-AppDisplayNames {
    $names = @{}
    try {
        foreach ($app in @(Get-StartApps)) {
            if (-not $names.ContainsKey([string] $app.AppID)) {
                $names[[string] $app.AppID] = [string] $app.Name
            }
        }
    }
    catch { }
    return $names
}

function Get-WindowsMediaState {
    param(
        [hashtable] $Context,
        [datetimeoffset] $Now = [DateTimeOffset]::Now
    )

    $sessions = @($Context.Manager.GetSessions())
    $session = Select-WindowsMediaSession `
        -Sessions $sessions `
        -CurrentSession $Context.Manager.GetCurrentSession() `
        -SelectedSessionId $Context.SelectedSessionId

    if ($null -eq $session) {
        $Context.SelectedSessionId = $null
        $Context.SelectedSession = $null
        return New-WindowsMediaIdleState
    }

    $sessionId = [string] $session.SourceAppUserModelId
    $Context.SelectedSessionId = $sessionId
    $Context.SelectedSession = $session
    $playback = $session.GetPlaybackInfo()
    $timeline = $session.GetTimelineProperties()
    $properties = Get-WinRtResult `
        -Operation $session.TryGetMediaPropertiesAsync() `
        -ResultType $Context.MediaPropertiesType
    $status = Convert-PlaybackStatus $playback.PlaybackStatus
    $rate = 1.0
    if ($null -ne $playback.PlaybackRate) { $rate = [double] $playback.PlaybackRate }

    $app = $sessionId
    if ($Context.AppDisplayNames.ContainsKey($sessionId)) {
        $app = $Context.AppDisplayNames[$sessionId]
    }

    return [ordered]@{
        type = 'media.state'
        source = 'windows-media'
        data = [ordered]@{
            sessionId = $sessionId
            app = $app
            status = $status
            title = if ([string]::IsNullOrWhiteSpace([string] $properties.Title)) { $null } else { [string] $properties.Title }
            artist = if ([string]::IsNullOrWhiteSpace([string] $properties.Artist)) { $null } else { [string] $properties.Artist }
            positionMs = Get-EstimatedPositionMilliseconds -Timeline $timeline -Status $status -PlaybackRate $rate -Now $Now
            durationMs = [long] [Math]::Round(($timeline.EndTime - $timeline.StartTime).TotalMilliseconds)
            thumbnailAvailable = $null -ne $properties.Thumbnail
        }
    }
}

function Get-MediaStateSignature {
    param($Message)
    return @(
        $Message.data.sessionId,
        $Message.data.app,
        $Message.data.status,
        $Message.data.title,
        $Message.data.artist,
        $Message.data.durationMs,
        $Message.data.thumbnailAvailable
    ) -join [char] 31
}

function New-WindowsMediaIdleState {
    return [ordered]@{
        type = 'media.state'
        source = 'windows-media'
        data = [ordered]@{
            sessionId = $null
            app = $null
            status = 'idle'
            title = $null
            artist = $null
            positionMs = $null
            durationMs = $null
            thumbnailAvailable = $false
        }
    }
}

function Start-WindowsMediaAdapter {
    param([hashtable] $Context)

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media, ContentType=WindowsRuntime]
    $Context.MediaPropertiesType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media, ContentType=WindowsRuntime]
    $Context.Manager = Get-WinRtResult -Operation $managerType::RequestAsync() -ResultType $managerType
    $Context.AppDisplayNames = Get-AppDisplayNames
    $Context.NextPollAt = [DateTimeOffset]::MinValue
    $Context.LastPositionEmissionAt = [DateTimeOffset]::MinValue
}

function Stop-WindowsMediaAdapter {
    param([hashtable] $Context)
    $Context.Manager = $null
    $Context.SelectedSession = $null
}

function Resolve-WindowsMediaLossState {
    param(
        [hashtable] $Context,
        $Message,
        [datetimeoffset] $Now
    )

    $isMissing = [string] $Message.data.status -eq 'idle' -and
        $null -eq $Message.data.sessionId
    if (-not $isMissing) {
        $Context.LastPresentMediaState = $Message
        $Context.MediaMissingSince = $null
        return $Message
    }

    if ($null -eq $Context.LastPresentMediaState) {
        return $Message
    }
    if ($null -eq $Context.MediaMissingSince) {
        $Context.MediaMissingSince = $Now
    }
    if (($Now - $Context.MediaMissingSince).TotalMilliseconds -lt
        $Context.MediaLossGraceMilliseconds) {
        return $null
    }

    $Context.LastPresentMediaState = $null
    $Context.MediaMissingSince = $null
    return $Message
}

function Poll-WindowsMediaAdapter {
    param([hashtable] $Context, [datetimeoffset] $Now)

    if ($Now -lt $Context.NextPollAt) { return $null }
    $Context.NextPollAt = $Now.AddMilliseconds($Context.PollMilliseconds)

    try {
        $message = Get-WindowsMediaState -Context $Context -Now $Now
    }
    catch {
        # Sessions can disappear between enumeration and property reads. Treat that
        # race as no active media and retry normally on the next poll.
        $Context.SelectedSessionId = $null
        $Context.SelectedSession = $null
        Write-Warning "[windows-media] state read failed: $($_.Exception.GetBaseException().Message)"
        $message = New-WindowsMediaIdleState
    }
    $message = Resolve-WindowsMediaLossState -Context $Context -Message $message -Now $Now
    if ($null -eq $message) { return $null }

    $signature = Get-MediaStateSignature -Message $message
    $changed = $signature -ne $Context.LastSignature
    $positionDue = ($Now - $Context.LastPositionEmissionAt).TotalMilliseconds -ge $Context.PositionEmissionMilliseconds
    if ($changed -or $positionDue) {
        $Context.LastSignature = $signature
        $Context.LastPositionEmissionAt = $Now
        return $message
    }
    return $null
}

function Invoke-WindowsMediaCommand {
    param([hashtable] $Context, $Message)

    if ([string] $Message.type -ne 'media.command') {
        throw "Windows media adapter does not handle '$($Message.type)'."
    }
    if ($null -eq $Message.data -or [string]::IsNullOrWhiteSpace([string] $Message.data.action)) {
        throw 'media.command is missing data.action.'
    }

    $session = $Context.SelectedSession
    if ($null -eq $session) {
        $null = Get-WindowsMediaState -Context $Context
        $session = $Context.SelectedSession
    }
    if ($null -eq $session) {
        throw 'No Windows media session is available.'
    }

    $action = ([string] $Message.data.action).ToLowerInvariant()
    switch ($action) {
        'play' { $accepted = & $Context.AwaitBoolean $session.TryPlayAsync() }
        'pause' { $accepted = & $Context.AwaitBoolean $session.TryPauseAsync() }
        'next' { $accepted = & $Context.AwaitBoolean $session.TrySkipNextAsync() }
        'previous' { $accepted = & $Context.AwaitBoolean $session.TrySkipPreviousAsync() }
        default { throw "Unsupported media action '$action'." }
    }

    $Context.NextPollAt = [DateTimeOffset]::MinValue
    return [ordered]@{
        type = 'command.result'
        source = 'windows-media'
        data = [ordered]@{
            commandType = 'media.command'
            action = $action
            accepted = $accepted
            sessionId = $Context.SelectedSessionId
        }
    }
}

function New-WindowsMediaAdapter {
    param(
        [int] $PollMilliseconds = 500,
        [int] $PositionEmissionMilliseconds = 5000,
        [int] $MediaLossGraceMilliseconds = 1500
    )

    return @{
        Name = 'windows-media'
        Context = @{
            Manager = $null
            MediaPropertiesType = $null
            AppDisplayNames = @{}
            SelectedSessionId = $null
            SelectedSession = $null
            LastSignature = $null
            NextPollAt = [DateTimeOffset]::MinValue
            LastPositionEmissionAt = [DateTimeOffset]::MinValue
            LastPresentMediaState = $null
            MediaMissingSince = $null
            PollMilliseconds = $PollMilliseconds
            PositionEmissionMilliseconds = $PositionEmissionMilliseconds
            MediaLossGraceMilliseconds = $MediaLossGraceMilliseconds
            AwaitBoolean = { param($operation) Get-WinRtBooleanResult $operation }
        }
        Start = { param($context) Start-WindowsMediaAdapter $context }
        Stop = { param($context) Stop-WindowsMediaAdapter $context }
        Poll = { param($context, $now) Poll-WindowsMediaAdapter $context $now }
        HandleCommand = { param($context, $message) Invoke-WindowsMediaCommand $context $message }
    }
}

Export-ModuleMember -Function @(
    'New-WindowsMediaAdapter',
    'New-WindowsMediaIdleState',
    'Get-EstimatedPositionMilliseconds',
    'Resolve-WindowsMediaLossState',
    'Select-WindowsMediaSession'
)
