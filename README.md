# Desktop pet

Minimal LCD bring-up for the Waveshare ESP32-C6-Touch-LCD-1.69 (SKU 31538).

Today's firmware is intentionally limited to initializing the board's ST7789V2
display and drawing two lines of text. Display pins, resolution, and panel
offsets come from Waveshare's official `05_gfx_helloworld` Arduino example.

## Toolchain

- Arduino CLI 1.5.1
- Espressif Arduino core 3.2.0 (Waveshare requires 3.2.0 or newer)
- GFX Library for Arduino 1.6.0

The core and library are pinned in `sketch.yaml`. Arduino CLI downloads them
into an isolated build-profile cache on the first build, so globally installed
Arduino libraries do not affect the result. The same profile selects the generic
ESP32-C6 target, enables USB CDC logging, and configures the board's physical
16 MB flash with Espressif's 3 MB application / 9.9 MB FATFS partition layout.

## Build

From this directory:

```powershell
arduino-cli compile --profile waveshare_esp32c6 .
```

## Flash

Connect the board over USB-C, close any serial monitor using its port, and run:

```powershell
arduino-cli upload --profile waveshare_esp32c6 --port COM_PORT .
```

Replace `COM_PORT` with the port shown by:

```powershell
arduino-cli board list
```

If automatic download mode fails, hold BOOT while resetting or reconnecting the
board, upload again, then reset the board after the upload finishes.

## Sources

- https://www.waveshare.com/wiki/ESP32-C6-Touch-LCD-1.69
- https://github.com/waveshareteam/ESP32-C6-Touch-LCD-1.69/tree/main/Examples/Arduino/examples/05_gfx_helloworld
