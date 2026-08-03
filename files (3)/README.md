# CastR Data Collector (iOS)

A minimal replacement for the WitMotion app: scans for your WT901BLE sensor,
streams live accel/gyro/angle data, and lets you record a session and export
it as a CSV in the same column format your `cast_analysis.py` script expects.

## What's here

- `CastRDataCollectorApp.swift` — app entry point
- `ContentView.swift` — the UI (scan, connect, live readings, record, export)
- `BLEManager.swift` — all Bluetooth logic: scanning, connecting, and parsing
  the sensor's raw byte stream into readings
- `SensorReading.swift` — the data model + CSV row formatting

## Setup (one-time)

1. Open Xcode → **File → New → Project → iOS → App**.
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Name it whatever you like (e.g. "CastRDataCollector")
2. Delete the default `ContentView.swift` Xcode generates, and drag in the
   four `.swift` files from this folder instead (make sure "Copy items if
   needed" is checked).
3. Add Bluetooth permission text. Select your project → target → **Info**
   tab → add a row:
   - Key: `Privacy - Bluetooth Always Usage Description`
   - Value: `CastR needs Bluetooth to connect to your casting sensor.`
4. Plug in your iPhone (or use the Simulator to check it builds, though
   Bluetooth only works on a real device), select it as the run target, and
   hit Run. You'll need a free Apple ID signed into Xcode to run on your own
   device (Settings → Accounts).

## Using it

1. Turn on your WT901BLE sensor.
2. Tap **Scan for Sensor** — it should show up in the list (named something
   like "WT901BLE67(...)").
3. Tap it to connect. Once connected you'll see live Acc/Gyro/Angle values
   updating.
4. Tap **Start Recording** before you begin casting, **Stop** when you're
   done, then **Export CSV** to share the file (AirDrop it to your Mac, save
   to Files, email it to yourself, etc.).
5. Run `python cast_analysis.py your_export.csv` (or open it in the
   segmentation script) the same way you did with the WitMotion app's
   exports — the columns line up.

## Known limitations / next steps

- **Only parses the standard 0x55/0x61 frame** (accel + gyro + angle). It
  does not yet request magnetometer or quaternion data — those need an
  extra register-read command to the write characteristic (0xFFE9), which
  isn't implemented yet. Your `cast_analysis.py` segmentation doesn't need
  them, so this wasn't a priority for v1.
- **No on-sensor configuration UI yet** (e.g. changing output rate to
  200Hz). That's sent via simple command bytes to the write characteristic
  (`FF AA 03 0B 00` for 200Hz, from WitMotion's own docs) — worth adding
  once you know what rate you want to standardize on.
- **CSV export uses the phone's local Bluetooth-notification timestamps**,
  not the sensor's internal clock — fine for cast-duration analysis, but if
  you ever need to sync with a separate video recording, timestamp drift
  is worth checking.
- Scanning currently filters on the WitMotion service UUID or a "WT901"
  name prefix — if your specific unit doesn't show up, let me know the
  exact name/UUID it advertises as and I'll adjust the filter.
