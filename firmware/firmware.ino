#include <Arduino_GFX_Library.h>
#include <ESP_I2S.h>
#include <TouchDrvCSTXXX.hpp>
#include <Wire.h>
#include <esp_err.h>

#include "audio_chirp.h"
#include "es8311.h"

// Display configuration from Waveshare's official 05_gfx_helloworld example
// for the ESP32-C6-Touch-LCD-1.69 (SKU 31538).
constexpr int LCD_SCK = 1;
constexpr int LCD_DIN = 2;
constexpr int LCD_CS = 5;
constexpr int LCD_DC = 3;
constexpr int LCD_RST = 4;
constexpr int LCD_BL = 6;
constexpr int I2C_SDA = 8;
constexpr int I2C_SCL = 7;
constexpr int TOUCH_IRQ = 11;
constexpr int I2S_MCLK = 19;
constexpr int I2S_BCLK = 20;
constexpr int I2S_WS = 22;
constexpr int I2S_DOUT = 23;
constexpr int I2S_DIN = 21;
constexpr int AUDIO_MCLK_MULTIPLE = 256;
constexpr int AUDIO_CODEC_VOLUME = 75;
constexpr size_t AUDIO_CHUNK_SAMPLES = 256;

Arduino_DataBus *bus = new Arduino_HWSPI(LCD_DC, LCD_CS, LCD_SCK, LCD_DIN);
Arduino_GFX *gfx = new Arduino_ST7789(
    bus, LCD_RST, 0 /* rotation */, true /* IPS */,
    240 /* width */, 280 /* height */,
    0 /* col offset 1 */, 20 /* row offset 1 */,
    0 /* col offset 2 */, 20 /* row offset 2 */);
TouchDrvCSTXXX touch;
volatile bool isPressed = false;
I2SClass i2s;
SemaphoreHandle_t beepSemaphore = nullptr;
bool audioReady = false;

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

void audioTask(void *arg) {
  static int16_t tone[AUDIO_CHUNK_SAMPLES];
  static const int16_t silence[AUDIO_CHUNK_SAMPLES] = {};

  while (true) {
    xSemaphoreTake(beepSemaphore, portMAX_DELAY);

    for (size_t offset = 0; offset < CHIRP_SAMPLE_COUNT;
         offset += AUDIO_CHUNK_SAMPLES) {
      size_t sampleCount =
          min(AUDIO_CHUNK_SAMPLES, CHIRP_SAMPLE_COUNT - offset);
      for (size_t i = 0; i < sampleCount; ++i) {
        tone[i] = TONE_CYCLE[(offset + i) % TONE_CYCLE_SAMPLES];
      }
      const size_t bytesRequested = sampleCount * sizeof(tone[0]);
      const size_t bytesWritten = i2s.write(
          reinterpret_cast<const uint8_t *>(tone), bytesRequested);
      if (bytesWritten != bytesRequested) {
        Serial.printf("audio: I2S.write failed: %u/%u bytes, error=%d\n",
                      static_cast<unsigned>(bytesWritten),
                      static_cast<unsigned>(bytesRequested), i2s.lastError());
        break;
      }
    }

    const size_t silenceBytesWritten =
        i2s.write(reinterpret_cast<const uint8_t *>(silence), sizeof(silence));
    if (silenceBytesWritten != sizeof(silence)) {
      Serial.printf("audio: silence write failed: %u/%u bytes, error=%d\n",
                    static_cast<unsigned>(silenceBytesWritten),
                    static_cast<unsigned>(sizeof(silence)), i2s.lastError());
    }
  }
}

bool setupAudio() {
  Wire.beginTransmission(ES8311_ADDRESS_0);
  const uint8_t probeResult = Wire.endTransmission(true);
  if (probeResult != 0) {
    Serial.printf("audio: ES8311 probe 0x%02X failed (Wire error %u)\n",
                  ES8311_ADDRESS_0, probeResult);
    return false;
  }

  es8311_handle_t codec = es8311_create(I2C_NUM_0, ES8311_ADDRESS_0);
  if (codec == nullptr) {
    Serial.println("audio: failed to create ES8311 codec");
    return false;
  }

  const es8311_clock_config_t clockConfig = {
      .mclk_inverted = false,
      .sclk_inverted = false,
      .mclk_from_mclk_pin = true,
      .mclk_frequency = CHIRP_SAMPLE_RATE * AUDIO_MCLK_MULTIPLE,
      .sample_frequency = CHIRP_SAMPLE_RATE,
  };

  esp_err_t result = es8311_init(codec, &clockConfig, ES8311_RESOLUTION_16,
                                 ES8311_RESOLUTION_16);
  if (result != ESP_OK) {
    Serial.printf("audio: ES8311 init failed: %s (%d)\n",
                  esp_err_to_name(result), result);
    es8311_delete(codec);
    return false;
  }

  result = es8311_voice_volume_set(codec, AUDIO_CODEC_VOLUME, nullptr);
  if (result != ESP_OK) {
    Serial.printf("audio: ES8311 volume failed: %s (%d)\n",
                  esp_err_to_name(result), result);
    es8311_delete(codec);
    return false;
  }

  result = es8311_microphone_config(codec, false);
  if (result != ESP_OK) {
    Serial.printf("audio: ES8311 microphone config failed: %s (%d)\n",
                  esp_err_to_name(result), result);
    es8311_delete(codec);
    return false;
  }

  i2s.setPins(I2S_BCLK, I2S_WS, I2S_DOUT, I2S_DIN, I2S_MCLK);
  if (!i2s.begin(I2S_MODE_STD, CHIRP_SAMPLE_RATE,
                 I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO,
                 I2S_STD_SLOT_LEFT)) {
    Serial.printf("audio: I2S init failed, error=%d\n", i2s.lastError());
    return false;
  }

  beepSemaphore = xSemaphoreCreateBinary();
  if (beepSemaphore == nullptr) {
    Serial.println("audio: failed to create beep semaphore");
    return false;
  }

  const BaseType_t taskResult =
      xTaskCreate(audioTask, "audio", 3072, nullptr, 2, nullptr);
  if (taskResult != pdPASS) {
    Serial.printf("audio: failed to start playback task (%ld)\n",
                  static_cast<long>(taskResult));
    return false;
  }

  Serial.println("audio ready; type beep and press Enter");
  return true;
}

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

  if (strcmp(inputBuffer, "beep") == 0) {
    if (audioReady) {
      const BaseType_t giveResult = xSemaphoreGive(beepSemaphore);
      Serial.println(giveResult == pdTRUE ? "beep queued"
                                          : "beep already queued");
    } else {
      Serial.println("audio unavailable");
    }
    inputLength = 0;
    inputTruncated = false;
    return;
  }

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
  Wire.begin(I2C_SDA, I2C_SCL);
  Serial.begin(115200);
  Serial.println("desktop pet LCD bring-up");

  if (!gfx->begin()) {
    Serial.println("gfx->begin() failed");
    return;
  }

  gfx->fillScreen(RGB565_BLACK);

  pinMode(LCD_BL, OUTPUT);
  digitalWrite(LCD_BL, HIGH);

  touch.setPins(-1, TOUCH_IRQ);
  touch.setTouchDrvModel(TouchDrv_CST8XX);
  if (!touch.begin(Wire, CST816_SLAVE_ADDRESS, I2C_SDA, I2C_SCL)) {
    Serial.println("failed to initialize touch");
    return;
  }

  isPressed = false;
  attachInterrupt(TOUCH_IRQ, []() { isPressed = true; }, FALLING);

  // Codec I2C traffic is setup-only; the playback task uses only I2S, so it
  // cannot contend with touch reads on the shared Wire bus.
  audioReady = setupAudio();
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

  int16_t x[5], y[5];
  if (isPressed) {
    isPressed = false;
    uint8_t touched = touch.getPoint(x, y, touch.getSupportTouchPoint());
    if (touched && x[0] >= 0 && x[0] < gfx->width() && y[0] >= 0 &&
        y[0] < gfx->height()) {
      Serial.print("touch x: ");
      Serial.print(x[0]);
      Serial.print(" y: ");
      Serial.println(y[0]);
      gfx->drawCircle(x[0], y[0], 2, RGB565_RED);
    }
  }

  delay(5);
}
