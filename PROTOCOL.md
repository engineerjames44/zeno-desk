# Zeno Desk: phone ↔ ESP32 ↔ Pi protocol (v1)

The iPhone app sends one small JSON message to the ESP32 charge controller on the home Wi-Fi.

## Endpoint

    POST http://zenodesk.local/telemetry
    Content-Type: application/json

- The ESP32 advertises itself over mDNS as `zenodesk` (so `zenodesk.local`), HTTP on port 80.
- The address is configurable in the app, so a plain IP (e.g. `http://192.0.2.50/telemetry`) also works.

## When the phone sends

- Every 60 s.
- Straight away when the charging state or the heat state changes.

## Body

```json
{"v":1,"battery":57,"charging":"charging","thermal":"nominal","seq":42}
```

| Field      | Type   | Values                                                    |
|------------|--------|-----------------------------------------------------------|
| `v`        | int    | Protocol version, always `1` for now                      |
| `battery`  | int    | 0–100 percent; `-1` if iOS doesn't know                   |
| `charging` | string | `"charging"`, `"full"`, `"unplugged"`, `"unknown"`        |
| `thermal`  | string | `"nominal"`, `"fair"`, `"serious"`, `"critical"`          |
| `seq`      | int    | Counts up by 1 each message; restarts at 0 when the app restarts |

Unknown extra fields should be ignored (room to grow).

## Reply: the box's stats

`200` with the same JSON as `GET /stats` below. The phone shows it on the day screen.
Anything that isn't 2xx is logged by the app and retried on the next tick.

## GET /stats (for the phone's reply and for Zeno on the Pi)

    GET http://zenodesk.local/stats

Zeno on the Pi calls this when James sends "deskstats" on Telegram.

```json
{"v":1,"relay":"charging","fan":false,
 "bus_v":5.08,"current_ma":912,"power_mw":4633,
 "temp_max_c":31.4,"temp_avg_c":null,"ambient_c":22.1,
 "phone":{"battery":57,"charging":"charging","thermal":"nominal","seq":42,"age_s":12},
 "uptime_s":86400,"rssi":-58}
```

| Field        | Meaning                                                                  |
|--------------|--------------------------------------------------------------------------|
| `relay`      | `"charging"` or `"off"`                                                  |
| `fan`        | fan on or off                                                            |
| `bus_v`, `current_ma`, `power_mw` | INA219 readings on the phone's USB power            |
| `temp_max_c` | **Phone temperature**: MLX90632 single-spot IR reading of the phone's back |
| `temp_avg_c` | Always `null` for now (the MLX90632 is one spot, not a camera); readers treat it as optional |
| `ambient_c`  | MLX90632's own sensor (ambient) temperature                       |
| `phone`      | the last telemetry heard from the phone, plus `age_s` = seconds since then; `null` if nothing heard since boot |
| `uptime_s`, `rssi` | ESP32 uptime and Wi-Fi signal strength                             |

A sensor that isn't working sends `null` for its fields. Unknown extra fields are ignored by both readers.

## Charging rule (lives on the ESP32, not in the app)

- `battery` < 40 → charging ON
- `battery` > 80 → charging OFF
- between 40 and 80 → keep the current state (hysteresis)
- `thermal` is `"serious"` or `"critical"` → charging OFF, whatever the battery
- no valid message for 15 min → charging ON (fail-safe) 
- `battery` = -1 → keep the current state

## Firmware v4: live numbers and test controls

    GET http://zenodesk.local/live

```json
{"v":1,"n":12345,"ms":678901,"relay":"charging","fan":true,"charge_mode":"auto","fan_mode":"auto",
 "bus_v":5.08,"current_ma":912,"power_mw":4633,"temp_c":31.42,"ambient_c":22.1,"phone_battery":57}
```

- Sensors refresh about 10 times a second. `n` counts up with each new sample (the app skips repeats); `ms` is box
  uptime when the sample was taken. A failed sensor sends `null`.
- The app polls this every 100 ms while the desk screen is awake (not at night, not in the background).
- A box on firmware v3 answers 404: the app then reads `GET /stats` once a second and tries `/live` again every 15 s.
- The battery % the app shows is the phone's own reading, not `phone_battery`.

    POST http://zenodesk.local/control?fan=on|off|auto&charge=on|off|auto

Replies with the `/live` JSON. Manual settings go back to auto on the box after 10 minutes. The graphs screen has
test buttons for it.

`POST /telemetry` (every 60 s, drives the charging rule) and `GET /stats` are unchanged.
