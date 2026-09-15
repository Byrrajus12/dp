#include <Arduino_GFX_Library.h>

// Display configuration from Waveshare's official 05_gfx_helloworld example
// for the ESP32-C6-Touch-LCD-1.69 (SKU 31538).
constexpr int LCD_SCK = 1;
constexpr int LCD_DIN = 2;
constexpr int LCD_CS = 5;
constexpr int LCD_DC = 3;
constexpr int LCD_RST = 4;
constexpr int LCD_BL = 6;

Arduino_DataBus *bus = new Arduino_HWSPI(LCD_DC, LCD_CS, LCD_SCK, LCD_DIN);
Arduino_GFX *gfx = new Arduino_ST7789(
    bus, LCD_RST, 0 /* rotation */, true /* IPS */,
    240 /* width */, 280 /* height */,
    0 /* col offset 1 */, 20 /* row offset 1 */,
    0 /* col offset 2 */, 20 /* row offset 2 */);

void setup() {
  Serial.begin(115200);
  Serial.println("desktop pet LCD bring-up");

  if (!gfx->begin()) {
    Serial.println("gfx->begin() failed");
    return;
  }

  gfx->fillScreen(RGB565_BLACK);

  pinMode(LCD_BL, OUTPUT);
  digitalWrite(LCD_BL, HIGH);

  gfx->setTextColor(RGB565_WHITE);
  gfx->setTextSize(3);
  gfx->setCursor(22, 90);
  gfx->setCursor(48, 135);
  gfx->println("hello :)");
}

void loop() {}
