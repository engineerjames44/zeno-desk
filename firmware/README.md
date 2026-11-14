# Zeno Desk charge controller (ESP32)

Arduino sketch for the "black box": an Adafruit Feather ESP32 V2 that keeps the desk iPhone's battery between 40% and
80%, reads the charging current and voltage (INA219) and the phone's temperature (MLX90632 IR sensor), runs a 5 V fan,
and serves the phone, the Pi and the live graphs over HTTP. Wiring and pins are at the top of
[`ZenoDesk/ZenoDesk.ino`](ZenoDesk/ZenoDesk.ino); the HTTP endpoints are in [`../PROTOCOL.md`](../PROTOCOL.md).

## Build

1. Copy `ZenoDesk/secrets.example.h` to `ZenoDesk/secrets.h` (gitignored) and fill in your Wi-Fi details.
2. Open `ZenoDesk/ZenoDesk.ino` in the Arduino IDE (the folder name must stay `ZenoDesk`).
3. Board: Adafruit Feather ESP32 V2. Libraries: Adafruit INA219, SparkFun MLX90632.
4. Upload once over USB. After that, updates can go over Wi-Fi if `OTA_PASSWORD` is set.

## Charging rule

Below 40%: charge. Above 80%: stop. In between: no change. iOS heat state "serious" or "critical": stop. No word from
the phone for 15 minutes: charge (fail-safe). The relay is wired through its normally closed contact, so a box that
loses power or resets leaves the phone charging.
