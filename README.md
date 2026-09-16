# Desktop pet

Minimal LCD bring-up for the Waveshare ESP32-C6-Touch-LCD-1.69 (SKU 31538).

Today's firmware is intentionally limited to initializing the board's ST7789V2
display and drawing two lines of text. Display pins, resolution, and panel
offsets come from Waveshare's official `05_gfx_helloworld` Arduino example.

## Toolchain

- Arduino CLI 1.5.1
- Espressif Arduino core 3.2.0 (Waveshare requires 3.2.0 or newer)
- GFX Library for Arduino 1.6.0

The core and library are pinned in `firmware/sketch.yaml`. Arduino CLI downloads
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

## Sources

- https://www.waveshare.com/wiki/ESP32-C6-Touch-LCD-1.69
- https://github.com/waveshareteam/ESP32-C6-Touch-LCD-1.69/tree/main/Examples/Arduino/examples/05_gfx_helloworld
