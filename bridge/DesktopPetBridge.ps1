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
    [switch] $SendApprovalRequested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($InitialBackoffMilliseconds -gt $MaxBackoffMilliseconds) {
    throw 'InitialBackoffMilliseconds cannot exceed MaxBackoffMilliseconds.'
}

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$stopRequested = $false
$approvalPending = $SendApprovalRequested.IsPresent
$backoffMilliseconds = $InitialBackoffMilliseconds
$inputAvailable = -not [Console]::IsInputRedirected

function Write-BridgeLog {
    param([string] $Message)

    Write-Host "[bridge] $Message"
    [Console]::Out.Flush()
}

function Send-NdjsonEvent {
    param(
        [System.Net.Sockets.NetworkStream] $Stream,
        [hashtable] $Event
    )

    $json = $Event | ConvertTo-Json -Compress -Depth 8
    $payload = $utf8.GetBytes("$json`n")
    if (($payload.Length - 1) -gt $MaxMessageBytes) {
        throw "Outgoing message exceeds the $MaxMessageBytes-byte limit."
    }

    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
    Write-BridgeLog "sent: $json"
}

function Receive-NdjsonBytes {
    param(
        [System.Collections.Generic.List[byte]] $PendingBytes,
        [byte[]] $Bytes,
        [int] $Count
    )

    for ($index = 0; $index -lt $Count; $index++) {
        $value = $Bytes[$index]
        if ($value -eq 10) {
            if ($PendingBytes.Count -gt 0 -and $PendingBytes[$PendingBytes.Count - 1] -eq 13) {
                $PendingBytes.RemoveAt($PendingBytes.Count - 1)
            }

            $line = $utf8.GetString($PendingBytes.ToArray())
            $PendingBytes.Clear()
            if ($line.Length -eq 0) {
                continue
            }

            try {
                $null = $line | ConvertFrom-Json -ErrorAction Stop
                Write-BridgeLog "incoming: $line"
            }
            catch {
                Write-Warning "[bridge] ignored invalid JSON: $line"
            }
        }
        else {
            if ($PendingBytes.Count -ge $MaxMessageBytes) {
                throw "Incoming message exceeds the $MaxMessageBytes-byte limit."
            }
            $PendingBytes.Add($value)
        }
    }
}

Write-BridgeLog "target is ${PetHost}:$Port (maximum message: $MaxMessageBytes bytes)"
Write-BridgeLog "commands: approval.requested, quit"

while (-not $stopRequested) {
    $client = [System.Net.Sockets.TcpClient]::new()
    $connectedAt = $null

    try {
        Write-BridgeLog "connecting to ${PetHost}:$Port"
        $connectTask = $client.ConnectAsync($PetHost, $Port)
        if (-not $connectTask.Wait(3000)) {
            throw 'Connection attempt timed out.'
        }
        $null = $connectTask.GetAwaiter().GetResult()

        $client.NoDelay = $true
        $connectedAt = [DateTime]::UtcNow
        $stream = $client.GetStream()
        $pendingBytes = [System.Collections.Generic.List[byte]]::new()
        $readBuffer = [byte[]]::new(1024)
        Write-BridgeLog "connected to ${PetHost}:$Port"

        Send-NdjsonEvent -Stream $stream -Event @{
            type = 'system.hello'
            source = 'pc-bridge'
            data = @{ protocol = 1 }
        }

        if ($approvalPending) {
            Send-NdjsonEvent -Stream $stream -Event @{
                type = 'approval.requested'
                source = 'codex'
            }
            $approvalPending = $false
        }

        while (-not $stopRequested) {
            while ($stream.DataAvailable) {
                $bytesRead = $stream.Read($readBuffer, 0, $readBuffer.Length)
                if ($bytesRead -eq 0) {
                    throw 'Pet closed the connection.'
                }
                Receive-NdjsonBytes -PendingBytes $pendingBytes -Bytes $readBuffer -Count $bytesRead
            }

            if ($client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and
                $client.Client.Available -eq 0) {
                throw 'Pet closed the connection.'
            }

            if ($inputAvailable) {
                try {
                    $hasConsoleInput = [Console]::KeyAvailable
                }
                catch {
                    $inputAvailable = $false
                    $hasConsoleInput = $false
                }

                if ($hasConsoleInput) {
                    $command = [Console]::ReadLine()
                    switch ($command.Trim()) {
                        '' { }
                        'approval.requested' {
                            Send-NdjsonEvent -Stream $stream -Event @{
                                type = 'approval.requested'
                                source = 'codex'
                            }
                        }
                        'quit' { $stopRequested = $true }
                        default { Write-Warning "[bridge] unknown command '$command'" }
                    }
                }
            }

            Start-Sleep -Milliseconds 50
        }
    }
    catch {
        if (-not $stopRequested) {
            Write-BridgeLog "disconnected: $($_.Exception.GetBaseException().Message)"
        }
    }
    finally {
        $client.Dispose()
    }

    if (-not $stopRequested) {
        if ($null -ne $connectedAt -and
            ([DateTime]::UtcNow - $connectedAt).TotalSeconds -ge 10) {
            $backoffMilliseconds = $InitialBackoffMilliseconds
        }

        Write-BridgeLog "reconnecting in $backoffMilliseconds ms"
        Start-Sleep -Milliseconds $backoffMilliseconds
        $backoffMilliseconds = [Math]::Min(
            $backoffMilliseconds * 2,
            $MaxBackoffMilliseconds
        )
    }
}

Write-BridgeLog 'stopped'
