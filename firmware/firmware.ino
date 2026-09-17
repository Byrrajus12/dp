#include <Arduino_GFX_Library.h>
#include <ESP_I2S.h>
#include <SensorQMI8658.hpp>
#include <TouchDrvCSTXXX.hpp>
#include <WiFi.h>
#include <Wire.h>
#include <errno.h>
#include <esp_err.h>
#include <lwip/sockets.h>
#include <math.h>

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
constexpr uint32_t MIC_TEST_DURATION_MS = 2400;
constexpr uint32_t MIC_REPORT_INTERVAL_MS = 200;
constexpr size_t MIC_READ_SAMPLES = 240;
constexpr size_t MIC_TEST_SAMPLES =
    CHIRP_SAMPLE_RATE * MIC_TEST_DURATION_MS / 1000;
constexpr size_t MIC_REPORT_SAMPLES =
    CHIRP_SAMPLE_RATE * MIC_REPORT_INTERVAL_MS / 1000;
constexpr uint32_t IMU_TEST_DURATION_MS = 5000;
constexpr uint32_t IMU_REPORT_INTERVAL_MS = 125;

Arduino_DataBus *bus = new Arduino_HWSPI(LCD_DC, LCD_CS, LCD_SCK, LCD_DIN);
Arduino_GFX *gfx = new Arduino_ST7789(
    bus, LCD_RST, 0 /* rotation */, true /* IPS */,
    240 /* width */, 280 /* height */,
    0 /* col offset 1 */, 20 /* row offset 1 */,
    0 /* col offset 2 */, 20 /* row offset 2 */);
TouchDrvCSTXXX touch;
SensorQMI8658 qmi;
volatile bool isPressed = false;
I2SClass i2s;
SemaphoreHandle_t beepSemaphore = nullptr;
SemaphoreHandle_t micSemaphore = nullptr;
bool audioReady = false;
bool micReady = false;
bool wifiStarted = false;
bool wifiConnected = false;
bool imuReady = false;
bool imuTestActive = false;
uint32_t imuTestStartMs = 0;
uint32_t imuLastReportMs = 0;
uint32_t imuSampleCount = 0;
uint32_t imuReadFailureCount = 0;

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

void micTask(void *arg) {
  static int16_t samples[MIC_READ_SAMPLES];

  while (true) {
    xSemaphoreTake(micSemaphore, portMAX_DELAY);

    Serial.printf("mic start: duration=%lu ms sample_rate=%lu Hz\n",
                  static_cast<unsigned long>(MIC_TEST_DURATION_MS),
                  static_cast<unsigned long>(CHIRP_SAMPLE_RATE));

    size_t totalSamples = 0;
    uint64_t totalSquares = 0;
    uint32_t totalPeak = 0;
    size_t reportSamples = 0;
    uint64_t reportSquares = 0;
    uint32_t reportPeak = 0;

    while (totalSamples < MIC_TEST_SAMPLES) {
      const size_t samplesRequested =
          min(MIC_READ_SAMPLES, MIC_TEST_SAMPLES - totalSamples);
      const size_t bytesRequested = samplesRequested * sizeof(samples[0]);
      const size_t bytesRead =
          i2s.readBytes(reinterpret_cast<char *>(samples), bytesRequested);
      const size_t samplesRead = bytesRead / sizeof(samples[0]);

      for (size_t i = 0; i < samplesRead; ++i) {
        const int32_t sample = samples[i];
        const uint32_t magnitude =
            sample < 0 ? static_cast<uint32_t>(-sample)
                       : static_cast<uint32_t>(sample);
        const uint64_t square =
            static_cast<uint64_t>(static_cast<int64_t>(sample) * sample);

        totalSquares += square;
        reportSquares += square;
        totalPeak = max(totalPeak, magnitude);
        reportPeak = max(reportPeak, magnitude);
        ++totalSamples;
        ++reportSamples;

        if (reportSamples == MIC_REPORT_SAMPLES) {
          const double rms =
              sqrt(static_cast<double>(reportSquares) / reportSamples);
          const uint32_t elapsedMs =
              totalSamples * 1000UL / CHIRP_SAMPLE_RATE;
          Serial.printf("mic %lu ms: samples=%u rms=%.1f peak=%lu\n",
                        static_cast<unsigned long>(elapsedMs),
                        static_cast<unsigned>(reportSamples), rms,
                        static_cast<unsigned long>(reportPeak));
          reportSamples = 0;
          reportSquares = 0;
          reportPeak = 0;
        }
      }

      if (bytesRead != bytesRequested) {
        Serial.printf("mic: I2S.readBytes failed: %u/%u bytes, error=%d\n",
                      static_cast<unsigned>(bytesRead),
                      static_cast<unsigned>(bytesRequested), i2s.lastError());
        break;
      }
    }

    const double totalRms =
        totalSamples > 0
            ? sqrt(static_cast<double>(totalSquares) / totalSamples)
            : 0.0;
    Serial.printf("mic summary: samples=%u rms=%.1f peak=%lu\n",
                  static_cast<unsigned>(totalSamples), totalRms,
                  static_cast<unsigned long>(totalPeak));
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

bool setupMicrophoneTest() {
  if (!audioReady) {
    return false;
  }

  micSemaphore = xSemaphoreCreateBinary();
  if (micSemaphore == nullptr) {
    Serial.println("mic: failed to create semaphore");
    return false;
  }

  const BaseType_t taskResult =
      xTaskCreate(micTask, "mic", 3072, nullptr, 2, nullptr);
  if (taskResult != pdPASS) {
    Serial.printf("mic: failed to start task (%ld)\n",
                  static_cast<long>(taskResult));
    return false;
  }

  Serial.println("microphone test ready; type mic and press Enter");
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

void queueMicTest() {
  if (micReady) {
    const BaseType_t giveResult = xSemaphoreGive(micSemaphore);
    Serial.println(giveResult == pdTRUE ? "mic test queued"
                                        : "mic test already queued");
  } else {
    Serial.println("microphone unavailable");
  }
}

bool setupImu() {
  // SensorLib's I2C adapter calls Wire.begin(), but Arduino-ESP32 leaves an
  // already-active bus intact. Omitting SDA/SCL also avoids setPins() on the
  // shared bus after touch has initialized it.
  if (!qmi.begin(Wire, QMI8658_L_SLAVE_ADDRESS)) {
    Serial.println("imu: QMI8658 not found; continuing without IMU");
    return false;
  }

  const uint8_t whoAmI = qmi.whoAmI();
  const uint8_t revision = qmi.getChipID();
  Serial.printf("imu found: whoami=0x%02X revision=0x%02X\n", whoAmI,
                revision);

  // In 6-axis mode the gyroscope selects the effective shared ODR, so these
  // settings produce about 112 Hz data while retaining useful motion range.
  if (qmi.configAccelerometer(SensorQMI8658::ACC_RANGE_4G,
                              SensorQMI8658::ACC_ODR_125Hz,
                              SensorQMI8658::LPF_MODE_3) != 0 ||
      qmi.configGyroscope(SensorQMI8658::GYR_RANGE_512DPS,
                          SensorQMI8658::GYR_ODR_112_1Hz,
                          SensorQMI8658::LPF_MODE_3) != 0 ||
      !qmi.enableAccelerometer() || !qmi.enableGyroscope()) {
    Serial.println("imu: configuration failed; continuing without IMU");
    return false;
  }

  Serial.println("imu ready; type imu and press Enter");
  return true;
}

void startImuTest() {
  if (!imuReady) {
    Serial.println("imu unavailable");
    return;
  }
  if (imuTestActive) {
    Serial.println("imu test already running");
    return;
  }

  imuTestActive = true;
  imuTestStartMs = millis();
  imuLastReportMs = imuTestStartMs - IMU_REPORT_INTERVAL_MS;
  imuSampleCount = 0;
  imuReadFailureCount = 0;
  Serial.printf("imu start: duration=%lu ms report_rate=8 Hz\n",
                static_cast<unsigned long>(IMU_TEST_DURATION_MS));
}

void updateImuTest() {
  if (!imuTestActive) {
    return;
  }

  const uint32_t now = millis();
  const uint32_t elapsedMs = now - imuTestStartMs;
  if (elapsedMs >= IMU_TEST_DURATION_MS) {
    imuTestActive = false;
    Serial.printf("imu summary: samples=%lu read_failures=%lu\n",
                  static_cast<unsigned long>(imuSampleCount),
                  static_cast<unsigned long>(imuReadFailureCount));
    return;
  }

  if (now - imuLastReportMs < IMU_REPORT_INTERVAL_MS ||
      !qmi.getDataReady()) {
    return;
  }
  imuLastReportMs = now;

  IMUdata accel;
  IMUdata gyro;
  const bool accelOk = qmi.getAccelerometer(accel.x, accel.y, accel.z);
  const bool gyroOk = qmi.getGyroscope(gyro.x, gyro.y, gyro.z);
  if (!accelOk || !gyroOk) {
    ++imuReadFailureCount;
    return;
  }

  const float accelMagnitude =
      sqrtf(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z);
  Serial.printf(
      "imu %4lu ms: accel_g x=%7.3f y=%7.3f z=%7.3f |a|=%6.3f "
      "gyro_dps x=%8.2f y=%8.2f z=%8.2f temp_c=%5.1f\n",
      static_cast<unsigned long>(elapsedMs), accel.x, accel.y, accel.z,
      accelMagnitude, gyro.x, gyro.y, gyro.z, qmi.getTemperature_C());
  ++imuSampleCount;
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

  if (strcmp(inputBuffer, "mic") == 0) {
    queueMicTest();
    inputLength = 0;
    inputTruncated = false;
    return;
  }

  if (strcmp(inputBuffer, "imu") == 0) {
    startImuTest();
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

  imuReady = setupImu();

  // Codec I2C traffic is setup-only; the playback task uses only I2S, so it
  // cannot contend with touch reads on the shared Wire bus.
  audioReady = setupAudio();
  micReady = setupMicrophoneTest();
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

  updateImuTest();

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
