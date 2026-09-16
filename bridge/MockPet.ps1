[CmdletBinding()]
param(
    [Parameter()]
    [string] $ListenAddress = '127.0.0.1',

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int] $Port = 8765,

    [Parameter()]
    [ValidateRange(128, 1048576)]
    [int] $MaxMessageBytes = 8192
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$address = [System.Net.IPAddress]::Parse($ListenAddress)
$listener = [System.Net.Sockets.TcpListener]::new($address, $Port)

function Write-MockLog {
    param([string] $Message)

    Write-Host "[mock-pet] $Message"
    [Console]::Out.Flush()
}

function Send-MockResponse {
    param(
        [System.Net.Sockets.NetworkStream] $Stream,
        [string] $ReceivedType
    )

    $response = @{
        type = 'pet.received'
        source = 'mock-pet'
        data = @{ receivedType = $ReceivedType }
    } | ConvertTo-Json -Compress -Depth 4
    $payload = $utf8.GetBytes("$response`n")
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
    Write-MockLog "sent: $response"
}

$listener.Start()
Write-MockLog "listening on ${ListenAddress}:$Port (maximum message: $MaxMessageBytes bytes)"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $remote = $client.Client.RemoteEndPoint
            Write-MockLog "client connected: $remote"
            $stream = $client.GetStream()
            $pendingBytes = [System.Collections.Generic.List[byte]]::new()
            $buffer = [byte[]]::new(1024)

            while ($client.Connected) {
                $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
                if ($bytesRead -eq 0) {
                    break
                }

                for ($index = 0; $index -lt $bytesRead; $index++) {
                    $value = $buffer[$index]
                    if ($value -eq 10) {
                        if ($pendingBytes.Count -gt 0 -and
                            $pendingBytes[$pendingBytes.Count - 1] -eq 13) {
                            $pendingBytes.RemoveAt($pendingBytes.Count - 1)
                        }

                        $line = $utf8.GetString($pendingBytes.ToArray())
                        $pendingBytes.Clear()
                        if ($line.Length -eq 0) {
                            continue
                        }

                        try {
                            $message = $line | ConvertFrom-Json -ErrorAction Stop
                            Write-MockLog "received: $line"
                            $receivedType = if ($message.type) { $message.type } else { '(missing)' }
                            Send-MockResponse -Stream $stream -ReceivedType $receivedType
                        }
                        catch {
                            Write-Warning "[mock-pet] ignored invalid JSON: $line"
                        }
                    }
                    else {
                        if ($pendingBytes.Count -ge $MaxMessageBytes) {
                            throw "Incoming message exceeds the $MaxMessageBytes-byte limit."
                        }
                        $pendingBytes.Add($value)
                    }
                }
            }
        }
        catch {
            Write-MockLog "client error: $($_.Exception.GetBaseException().Message)"
        }
        finally {
            $client.Dispose()
            Write-MockLog 'client disconnected'
        }
    }
}
finally {
    $listener.Stop()
}
