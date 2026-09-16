#include <Arduino_GFX_Library.h>
#include <ESP_I2S.h>
#include <TouchDrvCSTXXX.hpp>
#include <WiFi.h>
#include <Wire.h>
#include <errno.h>
#include <esp_err.h>
#include <lwip/sockets.h>

#include "audio_chirp.h"
#include "es8311.h"
#include "wifi_secrets.h"

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
bool wifiStarted = false;
bool wifiConnected = false;

constexpr uint16_t TCP_PORT = 8765;
constexpr size_t MAX_TCP_MESSAGE_BYTES = 8192;
constexpr size_t TCP_READ_BUDGET = 1024;
NetworkServer tcpServer(TCP_PORT, 1);
NetworkClient tcpClient;
bool tcpListening = false;
char tcpInputBuffer[MAX_TCP_MESSAGE_BYTES + 1];
size_t tcpInputLength = 0;
bool tcpInputOversized = false;

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

void queueBeep() {
  if (audioReady) {
    const BaseType_t giveResult = xSemaphoreGive(beepSemaphore);
    Serial.println(giveResult == pdTRUE ? "beep queued"
                                        : "beep already queued");
  } else {
    Serial.println("audio unavailable");
  }
}

void setupWiFi() {
  if (!WiFi.mode(WIFI_STA)) {
    Serial.println("wifi: failed to enter station mode");
    return;
  }

  Serial.print("wifi mac: ");
  Serial.println(WiFi.macAddress());
  Serial.println("wifi connecting");

#if PET_WIFI_AUTH_MODE == PET_WIFI_AUTH_PERSONAL
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
#elif PET_WIFI_AUTH_MODE == PET_WIFI_AUTH_ENTERPRISE_PEAP
  WiFi.begin(WIFI_SSID, WPA2_AUTH_PEAP, WIFI_EAP_IDENTITY,
             WIFI_EAP_USERNAME, WIFI_PASSWORD, WIFI_EAP_CA_CERT);
#else
#error "Unsupported PET_WIFI_AUTH_MODE"
#endif

  wifiStarted = true;
}

void updateWiFi() {
  if (!wifiStarted) {
    return;
  }

  if (WiFi.status() == WL_CONNECTED) {
    if (!wifiConnected) {
      wifiConnected = true;
      Serial.print("wifi connected: ");
      Serial.println(WiFi.localIP());
    }
    return;
  }

  if (wifiConnected) {
    wifiConnected = false;
    Serial.println("wifi disconnected");
  }
}

void resetTcpInput() {
  tcpInputLength = 0;
  tcpInputOversized = false;
}

bool hasTcpClient() {
  return tcpClient.fd() >= 0;
}

bool isTcpPeerConnected() {
  // NetworkClient may already have bytes in its private receive buffer even
  // when the socket itself is at EOF. Drain those before acting on FIN.
  if (tcpClient.available() > 0) {
    return true;
  }

  const int socket = tcpClient.fd();
  if (socket < 0) {
    return false;
  }

  uint8_t byte;
  const int result = recv(socket, &byte, 1, MSG_DONTWAIT | MSG_PEEK);
  if (result > 0) {
    return true;
  }
  if (result == 0) {
    return false;
  }

  return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
}

void stopTcp() {
  if (hasTcpClient()) {
    tcpClient.stop();
    Serial.println("tcp client disconnected");
  }
  tcpServer.end();
  tcpListening = false;
  resetTcpInput();
}

void sendReceivedResponse(const char *receivedType) {
  tcpClient.print(
      "{\"type\":\"pet.received\",\"source\":\"desktop-pet\",\"data\":{\"receivedType\":\"");
  tcpClient.print(receivedType);
  tcpClient.print("\"}}\n");
}

void handleTcpLine() {
  if (tcpInputLength > 0 && tcpInputBuffer[tcpInputLength - 1] == '\r') {
    --tcpInputLength;
  }
  if (tcpInputLength == 0) {
    return;
  }

  tcpInputBuffer[tcpInputLength] = '\0';

  // Temporary transport bring-up logic: the line remains opaque UTF-8. These
  // exact tokens identify messages emitted by the existing bridge; this is not
  // intended to validate or generally parse JSON.
  const char *receivedType = "unknown";
  if (strstr(tcpInputBuffer, "\"type\":\"system.hello\"") != nullptr) {
    receivedType = "system.hello";
  } else if (strstr(tcpInputBuffer,
                    "\"type\":\"approval.requested\"") != nullptr) {
    receivedType = "approval.requested";
  }

  Serial.print("event: ");
  Serial.println(receivedType);
  sendReceivedResponse(receivedType);

  if (strcmp(receivedType, "approval.requested") == 0) {
    queueBeep();
  }
}

void updateTcp() {
  if (!wifiConnected) {
    if (tcpListening || hasTcpClient()) {
      stopTcp();
    }
    return;
  }

  if (!tcpListening) {
    tcpServer.begin();
    if (tcpServer) {
      tcpServer.setNoDelay(true);
      tcpListening = true;
      Serial.printf("tcp listening: %u\n", TCP_PORT);
    }
    return;
  }

  if (!hasTcpClient()) {
    tcpClient = tcpServer.accept();
    if (hasTcpClient()) {
      resetTcpInput();
      Serial.println("tcp client connected");
    }
    return;
  }

  size_t bytesRead = 0;
  while (bytesRead < TCP_READ_BUDGET && tcpClient.available() > 0) {
    const int value = tcpClient.read();
    if (value < 0) {
      break;
    }
    ++bytesRead;

    if (value == '\n') {
      if (!tcpInputOversized) {
        handleTcpLine();
      }
      resetTcpInput();
    } else if (!tcpInputOversized) {
      if (tcpInputLength < MAX_TCP_MESSAGE_BYTES) {
        tcpInputBuffer[tcpInputLength++] = static_cast<char>(value);
      } else {
        tcpInputOversized = true;
        Serial.println("tcp line exceeds 8192 bytes; discarded");
      }
    }
  }

  if (!isTcpPeerConnected()) {
    tcpClient.stop();
    resetTcpInput();
    Serial.println("tcp client disconnected");
  }
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
    queueBeep();
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
  setupWiFi();
}

void loop() {
  updateWiFi();
  updateTcp();

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
