# Desktop pet

Desktop-pet firmware and Windows host for the Waveshare
ESP32-C6-Touch-LCD-1.69 (SKU 31538). The firmware retains the board bring-up
tests and adds the normalized media UI, touch controls, Wi-Fi, and TCP/NDJSON
endpoint. Display pins, resolution, and panel offsets come from Waveshare's
official `05_gfx_helloworld` Arduino example.

## Toolchain

- Arduino CLI 1.5.1
- Espressif Arduino core 3.2.0 (Waveshare requires 3.2.0 or newer)
- ArduinoJson 6.21.6
- GFX Library for Arduino 1.6.0

The core and libraries are pinned in `firmware/sketch.yaml`. Arduino CLI downloads
them into an isolated build-profile cache on the first build, so globally
installed Arduino libraries do not affect the result. The same profile selects
the generic ESP32-C6 target, enables USB CDC logging, and configures the board's
physical 16 MB flash with Espressif's 3 MB application / 9.9 MB FATFS partition
layout.

`arduino.ps1` runs the repo-local Arduino CLI and keeps its data, downloads,
user directory, and build cache under `.arduino-cli`. The firmware lives in a
separate sketch directory so these toolchain files are not scanned as sketch
inputs.

## Build

From this directory:

```powershell
.\arduino.ps1 compile --profile waveshare_esp32c6 .\firmware
```

## Flash

Connect the board over USB-C, close any serial monitor using its port, and run:

```powershell
.\arduino.ps1 upload --profile waveshare_esp32c6 --port COM_PORT .\firmware
```

Replace `COM_PORT` with the port shown by:

```powershell
.\arduino.ps1 board list
```

If automatic download mode fails, hold BOOT while resetting or reconnecting the
board, upload again, then reset the board after the upload finishes.

## Windows bridge

The first PC-side bridge is a dependency-free PowerShell 7 script. It maintains
one TCP connection to the pet, sends and receives UTF-8 newline-delimited JSON,
and reconnects with bounded exponential backoff. It intentionally has no
discovery, TLS, authentication, acknowledgement, or durable queue yet.

Start the local mock pet in one PowerShell window:

```powershell
.\bridge\MockPet.ps1 -Port 8765
```

Start the bridge in another:

```powershell
.\bridge\DesktopPetBridge.ps1 -PetHost 127.0.0.1 -Port 8765
```

The bridge sends `system.hello` after every connection. In its terminal, enter
`approval.requested` to send that semantic event, or `quit` to stop. For a
non-interactive smoke run, `-SendApprovalRequested` queues one approval event
for the first successful connection.

Messages are limited to 8192 bytes by default on both sides; use
`-MaxMessageBytes` to select another limit. Run the integration check with:

```powershell
.\bridge\Test-Bridge.ps1
```

The check uses a free loopback port, validates traffic in both directions,
kills and restarts the mock pet, and verifies that the bridge reconnects and
sends a fresh hello.

## Desktop pet host

The product host is a small Windows PowerShell 5.1 process with four focused components:

- `DesktopPetHost.ps1` starts/stops adapters, polls their semantic events, and
  connects them to the transport.
- `AdapterRegistry.psm1` validates registration and routes targeted commands.
- `PetTransport.psm1` owns the persistent UTF-8 NDJSON TCP connection, bounded
  messages, hello, reconnect/backoff, and bidirectional traffic.
- `adapters/WindowsMediaAdapter.psm1` is the only GSMTC-aware component. It
  normalizes Windows media state and handles explicit `play`, `pause`, `next`,
  and `previous` actions.

Windows PowerShell 5.1 is intentional for this first integration: on the target
machine it provides the installed native WinRT projection required by GSMTC.
PowerShell 7 does not resolve the Windows media WinRT types there, the .NET SDK
is not installed, and Node would add a native dependency. Run the host with
`powershell.exe`, not `pwsh`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\host\DesktopPetHost.ps1 -PetHost 127.0.0.1 -Port 8765
```

Use `-NoPet` to inspect normalized media state without a TCP peer. State is
emitted on semantic changes and every five seconds while unchanged so position
remains useful without flooding the pet.

The adapter polls Windows media every 500 ms and suppresses a missing media
session for 1500 ms by default, emitting `idle` on the first poll at or after
that boundary. This keeps a normal track transition from briefly emitting
`idle`. Set
`-MediaLossGraceMilliseconds` to tune the grace period; explicit paused states
are emitted immediately.

The Windows media selection policy is sticky and deterministic. A selected
playing session remains selected. A different playing session can replace a
paused selection, preferring Windows' current session and then a stable source
ID order. With no playing session, the existing selection remains; otherwise
Windows' current session is chosen. With no sessions, the adapter emits `idle`.

Example state:

```json
{"type":"media.state","source":"windows-media","data":{"sessionId":"Chrome._crx_cinhimbnkkghhklpknlkffjgod","app":"YouTube Music","status":"playing","title":"Track","artist":"Artist","positionMs":123000,"durationMs":240000,"thumbnailAvailable":true}}
```

Commands are routed by `target` to the adapter:

```json
{"type":"media.command","target":"windows-media","data":{"action":"pause"}}
```

Run the host tests (the integration test issues a pause followed by a play to
the current Windows media session and leaves it playing):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\host\tests\Test-Host.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\host\tests\Test-MockIntegration.ps1
```

## Sources

- https://www.waveshare.com/wiki/ESP32-C6-Touch-LCD-1.69
- https://github.com/waveshareteam/ESP32-C6-Touch-LCD-1.69/tree/main/Examples/Arduino/examples/05_gfx_helloworld
