Set-StrictMode -Version Latest

function New-PetTransport {
    param(
        [Parameter(Mandatory = $true)][string] $HostName,
        [Parameter(Mandatory = $true)][int] $Port,
        [int] $MaxMessageBytes = 8192,
        [int] $InitialBackoffMilliseconds = 250,
        [int] $MaxBackoffMilliseconds = 5000
    )

    return @{
        HostName = $HostName
        Port = $Port
        MaxMessageBytes = $MaxMessageBytes
        InitialBackoffMilliseconds = $InitialBackoffMilliseconds
        MaxBackoffMilliseconds = $MaxBackoffMilliseconds
        BackoffMilliseconds = $InitialBackoffMilliseconds
        Client = $null
        Stream = $null
        ConnectTask = $null
        ConnectDeadline = [DateTimeOffset]::MinValue
        ConnectedAt = $null
        NextConnectAt = [DateTimeOffset]::MinValue
        PendingBytes = [System.Collections.Generic.List[byte]]::new()
        ReadBuffer = [byte[]]::new(2048)
        Outbound = [System.Collections.Generic.Queue[object]]::new()
        Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    }
}

function Write-TransportLog {
    param([string] $Message)
    Write-Host "[transport] $Message"
    [Console]::Out.Flush()
}

function Close-PetConnection {
    param(
        [hashtable] $Transport,
        [string] $Reason,
        [datetimeoffset] $Now = [DateTimeOffset]::Now
    )

    if ($null -ne $Transport.Client) {
        try { $Transport.Client.Dispose() } catch { }
    }

    $wasConnected = $null -ne $Transport.Stream
    $connectedAt = $Transport.ConnectedAt
    $Transport.Client = $null
    $Transport.Stream = $null
    $Transport.ConnectTask = $null
    $Transport.ConnectedAt = $null
    $Transport.PendingBytes.Clear()

    if ($wasConnected -and $null -ne $connectedAt -and
        ($Now - $connectedAt).TotalSeconds -ge 10) {
        $Transport.BackoffMilliseconds = $Transport.InitialBackoffMilliseconds
    }

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-TransportLog "disconnected: $Reason"
    }
    $Transport.NextConnectAt = $Now.AddMilliseconds($Transport.BackoffMilliseconds)
    Write-TransportLog "reconnecting in $($Transport.BackoffMilliseconds) ms"
    $Transport.BackoffMilliseconds = [Math]::Min(
        $Transport.BackoffMilliseconds * 2,
        $Transport.MaxBackoffMilliseconds
    )
}

function ConvertTo-NdjsonBytes {
    param([hashtable] $Transport, $Message)

    $json = $Message | ConvertTo-Json -Compress -Depth 10
    $bytes = $Transport.Utf8.GetBytes("$json`n")
    if (($bytes.Length - 1) -gt $Transport.MaxMessageBytes) {
        throw "Outgoing message exceeds the $($Transport.MaxMessageBytes)-byte limit."
    }
    return @{ Json = $json; Bytes = $bytes }
}

function Send-PetMessageNow {
    param([hashtable] $Transport, $Message)

    $encoded = ConvertTo-NdjsonBytes -Transport $Transport -Message $Message
    $Transport.Stream.Write($encoded.Bytes, 0, $encoded.Bytes.Length)
    $Transport.Stream.Flush()
    Write-TransportLog "sent: $($encoded.Json)"
}

function Send-PetMessage {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Transport,
        [Parameter(Mandatory = $true)] $Message
    )

    # Validate size before queueing. The queue is deliberately small and transient.
    $null = ConvertTo-NdjsonBytes -Transport $Transport -Message $Message
    if ($Transport.Outbound.Count -ge 64) {
        $null = $Transport.Outbound.Dequeue()
        Write-TransportLog 'outbound queue full; dropped oldest message'
    }
    $Transport.Outbound.Enqueue($Message)
}

function Start-PetConnectAttempt {
    param([hashtable] $Transport, [datetimeoffset] $Now)

    $client = [System.Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $Transport.Client = $client
    $Transport.ConnectTask = $client.ConnectAsync($Transport.HostName, $Transport.Port)
    $Transport.ConnectDeadline = $Now.AddSeconds(3)
    Write-TransportLog "connecting to $($Transport.HostName):$($Transport.Port)"
}

function Complete-PetConnectAttempt {
    param([hashtable] $Transport, [datetimeoffset] $Now)

    if ($Now -ge $Transport.ConnectDeadline -and -not $Transport.ConnectTask.IsCompleted) {
        Close-PetConnection -Transport $Transport -Reason 'Connection attempt timed out.' -Now $Now
        return
    }
    if (-not $Transport.ConnectTask.IsCompleted) {
        return
    }

    try {
        $null = $Transport.ConnectTask.GetAwaiter().GetResult()
        $Transport.Stream = $Transport.Client.GetStream()
        $Transport.ConnectTask = $null
        $Transport.ConnectedAt = $Now
        Write-TransportLog "connected to $($Transport.HostName):$($Transport.Port)"
        Send-PetMessageNow -Transport $Transport -Message ([ordered]@{
            type = 'system.hello'
            source = 'desktop-pet-host'
            data = [ordered]@{ protocol = 1 }
        })
    }
    catch {
        Close-PetConnection -Transport $Transport -Reason $_.Exception.GetBaseException().Message -Now $Now
    }
}

function Receive-PetMessages {
    param([hashtable] $Transport)

    $messages = @()
    while ($Transport.Stream.DataAvailable) {
        $count = $Transport.Stream.Read($Transport.ReadBuffer, 0, $Transport.ReadBuffer.Length)
        if ($count -eq 0) {
            throw 'Pet closed the connection.'
        }

        for ($index = 0; $index -lt $count; $index++) {
            $value = $Transport.ReadBuffer[$index]
            if ($value -eq 10) {
                if ($Transport.PendingBytes.Count -gt 0 -and
                    $Transport.PendingBytes[$Transport.PendingBytes.Count - 1] -eq 13) {
                    $Transport.PendingBytes.RemoveAt($Transport.PendingBytes.Count - 1)
                }
                $line = $Transport.Utf8.GetString($Transport.PendingBytes.ToArray())
                $Transport.PendingBytes.Clear()
                if ($line.Length -eq 0) { continue }
                try {
                    $message = $line | ConvertFrom-Json -ErrorAction Stop
                    Write-TransportLog "received: $line"
                    $messages += $message
                }
                catch {
                    Write-Warning "[transport] ignored invalid JSON: $line"
                }
            }
            else {
                if ($Transport.PendingBytes.Count -ge $Transport.MaxMessageBytes) {
                    throw "Incoming message exceeds the $($Transport.MaxMessageBytes)-byte limit."
                }
                $Transport.PendingBytes.Add($value)
            }
        }
    }
    return $messages
}

function Update-PetTransport {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Transport,
        [datetimeoffset] $Now = [DateTimeOffset]::Now
    )

    if ($null -eq $Transport.Client) {
        if ($Now -ge $Transport.NextConnectAt) {
            Start-PetConnectAttempt -Transport $Transport -Now $Now
        }
        return @()
    }
    if ($null -ne $Transport.ConnectTask) {
        Complete-PetConnectAttempt -Transport $Transport -Now $Now
        return @()
    }

    try {
        while ($Transport.Outbound.Count -gt 0) {
            Send-PetMessageNow -Transport $Transport -Message $Transport.Outbound.Dequeue()
        }

        $messages = @(Receive-PetMessages -Transport $Transport)
        if ($Transport.Client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and
            $Transport.Client.Client.Available -eq 0) {
            throw 'Pet closed the connection.'
        }
        return $messages
    }
    catch {
        Close-PetConnection -Transport $Transport -Reason $_.Exception.GetBaseException().Message -Now $Now
        return @()
    }
}

function Stop-PetTransport {
    param([Parameter(Mandatory = $true)][hashtable] $Transport)

    if ($null -ne $Transport.Client) {
        try { $Transport.Client.Dispose() } catch { }
    }
    $Transport.Client = $null
    $Transport.Stream = $null
    $Transport.ConnectTask = $null
}

Export-ModuleMember -Function @(
    'New-PetTransport',
    'Send-PetMessage',
    'Update-PetTransport',
    'Stop-PetTransport'
)
