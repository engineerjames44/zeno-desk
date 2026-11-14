// Zeno Desk, v4: 10 Hz live readings, remote test switch, and Wi-Fi updates.
// Board: Adafruit Feather ESP32 V2. Serial Monitor at 115200 baud.
//
// Wiring (as built):
//   Relay 8 (charging): IN8 <- GPIO 32. 5V into COM, NC out to INA219 V+.
//   Relay 7 (fan):      IN7 <- GPIO 33. 5V into COM, NO out to fan red.
//   INA219 FeatherWing: 3V, GND, SDA, SCL wired to the Feather.
//   MLX90632 IR sensor: Qwiic cable into the Feather's STEMMA QT port.
//
// This relay board is "active high": a HIGH pin switches a relay ON (found by testing).
// Charging goes through NC, so relay 8 OFF = phone charging (the fail-safe).
//
// Network (see zeno-desk-protocol.md):
//   POST /telemetry   the phone's battery report (every 60 s and on changes); replies with /stats
//   GET  /stats       full readings, for the phone and for Zeno
//   GET  /live        compact readings, refreshed 10 times a second, for live screens and graphs
//   POST /control     test switch: ?fan=on|off|auto  ?charge=on|off|auto  (manual expires after 10 min)
// Wi-Fi details and the update password live in secrets.h.
//
// How it's split: a sensor task reads the INA219 and the IR sensor as fast as they allow
// (about 10 Hz) on one core, while the web server and the rules run in loop() on the other.

#include <Wire.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include <Adafruit_INA219.h>
#include <SparkFun_MLX90632_Arduino_Library.h>
#include "secrets.h"

const int RELAY_CHARGE_PIN = 32;
const int RELAY_FAN_PIN    = 33;

const int RELAY_ON  = HIGH;
const int RELAY_OFF = LOW;

// Charging rule. The phone's battery % decides; heat and silence override it.
const int CHARGE_START_PCT = 40;   // below this: charge
const int CHARGE_STOP_PCT  = 80;   // above this: stop
const unsigned long SILENCE_FAILSAFE_MS = 15UL * 60UL * 1000UL;  // no report for 15 min: charge

// Automatic fan: on at or above FAN_ON_C, off at or below FAN_OFF_C.
const float FAN_ON_C  = 38.0;
const float FAN_OFF_C = 35.0;

// Manual overrides (Serial keys or /control) hand back to automatic after this long,
// so a forgotten test can never leave the phone uncharged or the fan stuck.
const unsigned long MANUAL_TIMEOUT_MS = 10UL * 60UL * 1000UL;

const unsigned long SAMPLE_MS = 100;   // 10 Hz

Adafruit_INA219 ina219;
MLX90632 irSensor;
WebServer server(80);
bool inaOk = false;
bool irOk  = false;
bool otaOn = false;

bool charging = true;    // relay 8 off, so NC closed
bool fanOn    = false;   // relay 7 off, so NO open
bool chargeAuto = true;
bool fanAuto    = true;
unsigned long chargeManualAt = 0;
unsigned long fanManualAt    = 0;

// Latest readings, written by the sensor task, read by everything else.
struct Readings {
  float busV = 0, currentMa = 0, powerMw = 0;
  float phoneC = NAN, ambientC = NAN;
  unsigned long n = 0;      // counts up with every new sample
  unsigned long atMs = 0;   // when it was taken
};
Readings latest;
portMUX_TYPE readingsLock = portMUX_INITIALIZER_UNLOCKED;

Readings snapshot() {
  portENTER_CRITICAL(&readingsLock);
  Readings r = latest;
  portEXIT_CRITICAL(&readingsLock);
  return r;
}

// Last report from the phone.
bool phoneHeard = false;
unsigned long phoneHeardAt = 0;
int phoneBattery = -1;
String phoneCharging = "unknown";
String phoneThermal  = "nominal";
long phoneSeq = 0;

void applyOutputs() {
  // Charging ON means relay 8 OFF.
  digitalWrite(RELAY_CHARGE_PIN, charging ? RELAY_OFF : RELAY_ON);
  digitalWrite(RELAY_FAN_PIN,    fanOn    ? RELAY_ON  : RELAY_OFF);
}

// --- Sensor task: runs on its own core so slow readings never stall the web server ---

void sensorTask(void *) {
  float smoothC = NAN;
  for (;;) {
    unsigned long start = millis();
    Readings r = snapshot();

    if (inaOk) {
      r.busV      = ina219.getBusVoltage_V();
      r.currentMa = ina219.getCurrent_mA();
      r.powerMw   = ina219.getPower_mW();
    }
    if (irOk) {
      MLX90632::status st;
      float c = irSensor.getObjectTemp(st);   // ~60 ms at the 32 Hz setting
      if (st == MLX90632::status::SENSOR_SUCCESS) {
        // Light smoothing: fast readings are a little noisy.
        smoothC = isnan(smoothC) ? c : smoothC + 0.4f * (c - smoothC);
        r.phoneC = smoothC;
        r.ambientC = irSensor.getSensorTemp();
      }
    }
    r.n++;
    r.atMs = millis();

    portENTER_CRITICAL(&readingsLock);
    latest = r;
    portEXIT_CRITICAL(&readingsLock);

    unsigned long took = millis() - start;
    vTaskDelay(pdMS_TO_TICKS(took < SAMPLE_MS ? SAMPLE_MS - took : 1));
  }
}

// --- Tiny JSON helpers for the phone's small, fixed message ---

long jsonNumber(const String &body, const char *key, long fallback) {
  String pat = String("\"") + key + "\"";
  int i = body.indexOf(pat);
  if (i < 0) return fallback;
  i = body.indexOf(':', i + pat.length());
  if (i < 0) return fallback;
  i++;
  while (i < (int)body.length() && body[i] == ' ') i++;
  if (i >= (int)body.length() || !(isDigit(body[i]) || body[i] == '-')) return fallback;
  return body.substring(i).toInt();
}

String jsonString(const String &body, const char *key, const String &fallback) {
  String pat = String("\"") + key + "\"";
  int i = body.indexOf(pat);
  if (i < 0) return fallback;
  i = body.indexOf(':', i + pat.length());
  if (i < 0) return fallback;
  int q1 = body.indexOf('"', i + 1);
  if (q1 < 0) return fallback;
  int q2 = body.indexOf('"', q1 + 1);
  if (q2 < 0) return fallback;
  return body.substring(q1 + 1, q2);
}

// A number with no padding, or null when the sensor isn't working.
String num(float x, int decimals) {
  if (isnan(x)) return "null";
  String s = String(x, decimals);
  s.trim();
  return s;
}

String statsJson() {
  Readings r = snapshot();
  String phone = "null";
  if (phoneHeard) {
    phone = "{\"battery\":" + String(phoneBattery) +
            ",\"charging\":\"" + phoneCharging + "\"" +
            ",\"thermal\":\"" + phoneThermal + "\"" +
            ",\"seq\":" + String(phoneSeq) +
            ",\"age_s\":" + String((millis() - phoneHeardAt) / 1000) + "}";
  }
  // The MLX90632 measures one spot, so temp_max_c is that spot and temp_avg_c is null.
  return "{\"v\":1"
         ",\"relay\":\"" + String(charging ? "charging" : "off") + "\"" +
         ",\"fan\":" + String(fanOn ? "true" : "false") +
         ",\"bus_v\":" + (inaOk ? num(r.busV, 2) : "null") +
         ",\"current_ma\":" + (inaOk ? num(r.currentMa, 0) : "null") +
         ",\"power_mw\":" + (inaOk ? num(r.powerMw, 0) : "null") +
         ",\"temp_max_c\":" + (irOk ? num(r.phoneC, 1) : "null") +
         ",\"temp_avg_c\":null" +
         ",\"ambient_c\":" + (irOk ? num(r.ambientC, 1) : "null") +
         ",\"phone\":" + phone +
         ",\"uptime_s\":" + String(millis() / 1000) +
         ",\"rssi\":" + String(WiFi.RSSI()) + "}";
}

// Small and fast, for 10 Hz polling.
String liveJson() {
  Readings r = snapshot();
  return "{\"v\":1"
         ",\"n\":" + String(r.n) +
         ",\"ms\":" + String(r.atMs) +
         ",\"relay\":\"" + String(charging ? "charging" : "off") + "\"" +
         ",\"fan\":" + String(fanOn ? "true" : "false") +
         ",\"charge_mode\":\"" + String(chargeAuto ? "auto" : "manual") + "\"" +
         ",\"fan_mode\":\"" + String(fanAuto ? "auto" : "manual") + "\"" +
         ",\"bus_v\":" + (inaOk ? num(r.busV, 2) : "null") +
         ",\"current_ma\":" + (inaOk ? num(r.currentMa, 0) : "null") +
         ",\"power_mw\":" + (inaOk ? num(r.powerMw, 0) : "null") +
         ",\"temp_c\":" + (irOk ? num(r.phoneC, 2) : "null") +
         ",\"ambient_c\":" + (irOk ? num(r.ambientC, 1) : "null") +
         ",\"phone_battery\":" + String(phoneHeard ? phoneBattery : -1) + "}";
}

// --- HTTP handlers ---

void handleTelemetry() {
  String body = server.arg("plain");
  if (body.length() == 0 || body.indexOf("\"battery\"") < 0) {
    server.send(400, "application/json", "{\"error\":\"expected telemetry JSON\"}");
    return;
  }
  phoneBattery  = jsonNumber(body, "battery", -1);
  phoneCharging = jsonString(body, "charging", "unknown");
  phoneThermal  = jsonString(body, "thermal", "nominal");
  phoneSeq      = jsonNumber(body, "seq", 0);
  phoneHeard    = true;
  phoneHeardAt  = millis();
  Serial.printf("<< Phone: %d%%  %s  heat=%s  seq=%ld\n",
                phoneBattery, phoneCharging.c_str(), phoneThermal.c_str(), phoneSeq);
  server.send(200, "application/json", statsJson());
}

void handleStats() { server.send(200, "application/json", statsJson()); }
void handleLive()  { server.send(200, "application/json", liveJson()); }

void handleControl() {
  String fan = server.arg("fan");
  String chg = server.arg("charge");
  if (fan == "on" || fan == "off") {
    fanAuto = false; fanManualAt = millis(); fanOn = (fan == "on");
  } else if (fan == "auto") {
    fanAuto = true;
  }
  if (chg == "on" || chg == "off") {
    chargeAuto = false; chargeManualAt = millis(); charging = (chg == "on");
  } else if (chg == "auto") {
    chargeAuto = true;
  }
  applyOutputs();
  Serial.printf(">> Control: fan=%s charge=%s\n", fan.c_str(), chg.c_str());
  server.send(200, "application/json", liveJson());
}

// --- The rules ---

void runRules(const Readings &r) {
  // Manual overrides expire.
  if (!chargeAuto && millis() - chargeManualAt > MANUAL_TIMEOUT_MS) chargeAuto = true;
  if (!fanAuto    && millis() - fanManualAt    > MANUAL_TIMEOUT_MS) fanAuto = true;

  if (fanAuto && irOk && !isnan(r.phoneC)) {
    if (!fanOn && r.phoneC >= FAN_ON_C)  { fanOn = true;  applyOutputs(); }
    if (fanOn  && r.phoneC <= FAN_OFF_C) { fanOn = false; applyOutputs(); }
  }

  if (!chargeAuto) return;
  bool want = charging;
  if (!phoneHeard || millis() - phoneHeardAt > SILENCE_FAILSAFE_MS) {
    want = true;                                   // never let the phone die silently
  } else if (phoneThermal == "serious" || phoneThermal == "critical") {
    want = false;                                  // too hot: stop, whatever the battery
  } else if (phoneBattery >= 0 && phoneBattery < CHARGE_START_PCT) {
    want = true;
  } else if (phoneBattery > CHARGE_STOP_PCT) {
    want = false;
  }                                                // 40-80% or unknown: keep as is
  if (want != charging) {
    charging = want;
    applyOutputs();
    Serial.println(charging ? ">> Rule: charging ON" : ">> Rule: charging OFF");
  }
}

void printHelp() {
  Serial.println();
  Serial.println("Commands:  c = charging on/off (manual)   f = fan on/off (manual)");
  Serial.println("           a = back to automatic          s = help");
}

void setup() {
  // Set the pins to "off" before making them outputs, so neither relay clicks on at boot.
  digitalWrite(RELAY_CHARGE_PIN, RELAY_OFF);
  digitalWrite(RELAY_FAN_PIN, RELAY_OFF);
  pinMode(RELAY_CHARGE_PIN, OUTPUT);
  pinMode(RELAY_FAN_PIN, OUTPUT);
  applyOutputs();

  Serial.begin(115200);
  delay(1000);
  Serial.println("Zeno Desk v4");

  // The Feather V2's STEMMA QT port is unpowered until this pin goes HIGH.
#ifdef NEOPIXEL_I2C_POWER
  pinMode(NEOPIXEL_I2C_POWER, OUTPUT);
  digitalWrite(NEOPIXEL_I2C_POWER, HIGH);
  delay(10);
#endif

  Wire.begin();            // Feather V2 default I2C pins: SDA 22, SCL 20 (shared with STEMMA QT)
  Wire.setClock(400000);   // fast I2C, so 10 Hz reads leave plenty of time

  inaOk = ina219.begin();
  if (!inaOk) Serial.println("INA219 not found. Check the 3V, GND, SDA and SCL wires.");

  MLX90632::status irStatus;
  irOk = irSensor.begin(MLX90632_DEFAULT_ADDRESS, Wire, irStatus);
  if (irOk) {
    irSensor.setMeasurementRate(32);  // 32 Hz internal, about 16 full readings a second.
                                      // Saved in the sensor; only written if it changes.
  } else {
    Serial.println("MLX90632 not found. Check the Qwiic cable.");
  }

  // Wi-Fi. The relays keep working even if this never connects.
  WiFi.mode(WIFI_STA);
  WiFi.setHostname("zenodesk");
  WiFi.setAutoReconnect(true);
  WiFi.setSleep(false);    // no Wi-Fi power saving: keeps 10 Hz replies quick
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Joining Wi-Fi");
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) {
    delay(250);
    Serial.print(".");
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("Wi-Fi OK, address: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("Wi-Fi not connected yet (check secrets.h). Will keep trying.");
  }

  if (MDNS.begin("zenodesk")) MDNS.addService("http", "tcp", 80);
  server.on("/telemetry", HTTP_POST, handleTelemetry);
  server.on("/stats", HTTP_GET, handleStats);
  server.on("/live", HTTP_GET, handleLive);
  server.on("/control", HTTP_POST, handleControl);
  server.begin();

  // Wi-Fi updates. An empty OTA_PASSWORD means no password: anyone on the home
  // Wi-Fi could update the box. Set one in secrets.h if that ever matters.
  if (String(OTA_PASSWORD) != "choose-an-update-password") {
    ArduinoOTA.setHostname("zenodesk");
    if (strlen(OTA_PASSWORD) > 0) ArduinoOTA.setPassword(OTA_PASSWORD);
    ArduinoOTA.onStart([]() {
      // Updates take a few seconds; put the phone's charging on the safe setting first.
      charging = true; fanOn = false; applyOutputs();
    });
    ArduinoOTA.begin();
    otaOn = true;
    Serial.println("Wi-Fi updates ON (port \"zenodesk\" in the Arduino IDE).");
  } else {
    Serial.println("Wi-Fi updates OFF: set OTA_PASSWORD in secrets.h to turn them on.");
  }

  // Sensors on core 0; the web server and rules stay on core 1 in loop().
  xTaskCreatePinnedToCore(sensorTask, "sensors", 4096, nullptr, 1, nullptr, 0);

  printHelp();
}

void loop() {
  server.handleClient();
  if (otaOn) ArduinoOTA.handle();

  // Keyboard commands from the Serial Monitor.
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == 'c') {
      chargeAuto = false; chargeManualAt = millis();
      charging = !charging;
      applyOutputs();
      Serial.println(charging ? ">> Charging ON (manual)" : ">> Charging OFF (manual)");
    } else if (ch == 'f') {
      fanAuto = false; fanManualAt = millis();
      fanOn = !fanOn;
      applyOutputs();
      Serial.println(fanOn ? ">> Fan ON (manual)" : ">> Fan OFF (manual)");
    } else if (ch == 'a') {
      chargeAuto = true;
      fanAuto = true;
      Serial.println(">> Charging and fan back to automatic");
    } else if (ch == 's') {
      printHelp();
    }
  }

  // Rules at 10 Hz; a status line once a second.
  static unsigned long lastRules = 0, lastPrint = 0;
  if (millis() - lastRules >= SAMPLE_MS) {
    lastRules = millis();
    runRules(snapshot());
  }
  if (millis() - lastPrint >= 1000) {
    lastPrint = millis();
    Readings r = snapshot();
    Serial.printf("Phone: %.2f V  %4.0f mA  %.1f C   battery=%d%%  charging=%s  fan=%s  wifi=%s  samples=%lu\n",
                  r.busV, r.currentMa, r.phoneC, phoneBattery,
                  charging ? "on" : "off",
                  fanOn ? "on" : "off",
                  WiFi.status() == WL_CONNECTED ? "ok" : "no",
                  r.n);
  }
  delay(1);
}
