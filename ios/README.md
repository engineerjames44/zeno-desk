# Zeno Desk (iPhone app)

An always-on desk display on a spare iPhone 12 Pro: pixel Zeno in a live weather window, the clock, Zeno's latest
news and phone calls, and live numbers from the Zeno Desk charge controller (ESP32 "black box").

## What it does

- **Day (6am–11pm):** landscape, 100% brightness, everything drifting slowly (OLED burn-in care).
- **Night (11pm–6am):** fully black, brightness 0, Zeno paused.
- **Telemetry:** every 60 s (and straight away on a charging or heat change) it POSTs battery %, charging state and
  iOS heat state to the box, which runs the 40–80% charging rule. See [PROTOCOL.md](../PROTOCOL.md).
- **Feed:** listens on port 8080 for `POST /feed` from the Pi (same JSON as the Zeno 64 TV feed).
- **Weather:** Open-Meteo for Boston, every 15 min. No account, no location access.
- **Live numbers:** polls the box 10 times a second (`GET /live`, firmware v4; falls back to `/stats` once a second).
- **Graphs:** double-tap the screen for live charts (current, volts, power, phone temp with fan bands, battery);
  double-tap or swipe to go back. Closes by itself after 5 min.
- **Hidden settings:** hold three fingers on the screen for 2 s (box address, last send, battery details).

## Build and install

First copy `Local.example.xcconfig` to `Local.xcconfig` and fill in your Apple team ID and the addresses allowed
to push Zeno's feed (that file is gitignored). Then open `ZenoCompanion.xcodeproj` in Xcode, pick the iPhone, Run.
Or from the terminal (`xcrun devicectl list devices` shows the phone's ID):

```
xcodebuild -project ZenoCompanion.xcodeproj -scheme ZenoCompanion -destination 'id=<iphone-id>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <iphone-id> build/Build/Products/Debug-iphoneos/ZenoCompanion.app
```

Signed with a free developer account, so the install stops launching after 7 days and must be reinstalled.

## Test tools (`tools/`)

- `fake_box.py`: a stand-in black box on the Mac.
- `PHONE=<phone-ip> tools/send_feed.sh news|call|clear`: push a test feed to the phone. Always finish with `clear`.
- `stage_call.py <phone-ip>`: play a made-up phone call on the desk, then clear it.
- Debug builds accept `-weatherCode <WMO code> -weatherDay 0|1` to preview any sky.

## Assets

`ZenoCompanion/Media/zeno-idle-alpha.mov` is the Zeno 64 pixel idle animation
(`~/Projects/zeno64/media/video/zeno-pixel-idle-transparent.mov`) re-encoded as HEVC with alpha.
