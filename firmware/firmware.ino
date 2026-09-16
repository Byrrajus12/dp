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

constexpr size_t MAX_TEXT_LENGTH = 256;
constexpr int TEXT_SIZE = 2;
constexpr int TEXT_MARGIN_X = 12;
constexpr int TEXT_MARGIN_Y = 12;
constexpr int TEXT_CHAR_WIDTH = 6 * TEXT_SIZE;
constexpr int TEXT_LINE_HEIGHT = 8 * TEXT_SIZE;
constexpr int MAX_CHARS_PER_LINE =
    (240 - (2 * TEXT_MARGIN_X)) / TEXT_CHAR_WIDTH;

char inputBuffer[MAX_TEXT_LENGTH + 1];
size_t inputLength = 0;
bool inputTruncated = false;

void displayText() {
  gfx->fillScreen(RGB565_BLACK);
  gfx->setTextColor(RGB565_WHITE);
  gfx->setTextSize(TEXT_SIZE);
  gfx->setCursor(TEXT_MARGIN_X, TEXT_MARGIN_Y);

  int charsOnLine = 0;
  for (size_t i = 0; i < inputLength; ++i) {
    if (charsOnLine == MAX_CHARS_PER_LINE) {
      gfx->setCursor(TEXT_MARGIN_X,
                     TEXT_MARGIN_Y + TEXT_LINE_HEIGHT * (i / MAX_CHARS_PER_LINE));
      charsOnLine = 0;
    }

    gfx->write(static_cast<uint8_t>(inputBuffer[i]));
    ++charsOnLine;
  }
}

void submitText() {
  inputBuffer[inputLength] = '\0';
  displayText();

  Serial.print("displayed ");
  Serial.print(inputLength);
  Serial.print(" chars");
  if (inputTruncated) {
    Serial.print(" (truncated at ");
    Serial.print(MAX_TEXT_LENGTH);
    Serial.print(")");
  }
  Serial.println();

  inputLength = 0;
  inputTruncated = false;
}

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

void loop() {
  while (Serial.available() > 0) {
    char received = static_cast<char>(Serial.read());

    if (received == '\n') {
      submitText();
    } else if (received != '\r') {
      if (inputLength < MAX_TEXT_LENGTH) {
        inputBuffer[inputLength++] = received;
      } else {
        inputTruncated = true;
      }
    }
  }
}
