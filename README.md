# CastR

Motion capture for casting analysis, built around a WitMotion **WT901BLE** IMU.
Replaces the WitMotion app and exports CSV in WitMotion's own column format, so
recordings drop into anything that already reads those exports.

Two ways to collect:

| | Runs on | Needs Xcode | Status |
|---|---|---|---|
| **`castr-collect`** | macOS, tethered | No | Working |
| **CastR iOS app** | iPhone, in the field | Yes | Sources present, not yet buildable |

The Mac CLI exists because Xcode is a ~10 GB install and the iOS app can't be built
without it. Both share the same parsing and CSV code (`CastrCore`), so whatever the CLI
proves about the sensor carries straight over to the phone.

## Quick start (no Xcode needed)

```sh
swift build                              # ~2.5 min cold on an Intel Mac
swift run castr-selftest                 # 116 checks, no hardware required
./.build/debug/castr-collect --help
```

Then, with the sensor powered on:

```sh
./.build/debug/castr-collect -o backyard.csv
```

Ctrl-C to stop. **The CSV is valid at every instant** — rows stream to disk as they
arrive, so killing the process, or a dead battery, costs you at most the last ~50
samples rather than the whole session.

### Options

```
-o, --out <path>     Write CSV here (default: ./CastR_<timestamp>.csv)
    --check          Health check: is the sensor reading 1 g at rest?
    --raw            Hex-dump packets instead of parsing
    --any            List every BLE peripheral, not just WitMotion ones
    --replay <file>  Feed a hex fixture through the parser; no hardware
    --rate <hz>      Set sensor output rate (10|20|50|100|200) and save it
    --device <name>  Only connect to a device whose name contains this
    --seconds <n>    Stop automatically after n seconds
```

The live status line reports sample count, measured rate, current acceleration, and a
**rejected-frame count**. That last number is the one to watch: the sensor's frame
format carries no checksum, so a rising reject count is the only signal that framing has
gone wrong and the CSV can't be trusted.

## First time with the sensor — bring-up

Run these in order. Each one gates the next, so a failure tells you exactly where the
problem is instead of leaving you guessing at a silent empty CSV.

**1. What is it called?**

```sh
./.build/debug/castr-collect --any --seconds 10
```

Look for your unit. Note the exact name and whether it says `advertises FFE5`. Many
WT901BLE units do **not** put the service UUID in their advertisement — that's expected
and handled, but it's worth knowing which kind you have.

**2. What do its packets look like?**

```sh
./.build/debug/castr-collect --raw --device WT
```

You should see 20-byte lines starting `5561`. If instead you see 11-byte packets
starting `5551`, `5552`, or `5553`, your unit ships the older frame format and
`FrameParser` needs a second decoder — the current one will produce **nothing at all**.
Save a few lines of that output.

**3. Does it read sane values at rest?**

```sh
./.build/debug/castr-collect --check     # sensor flat on a table, don't touch it
```

A resting accelerometer must measure exactly 1 g. That one fact catches scale errors,
zero-offset drift and framing bugs at once, which is why this is the gate before any
real recording:

```
  samples          2984 over 15.0s  (199 Hz)
  [ok  ] stillness    gyro mean 0.04 °/s, peak 0.31 °/s
  [ok  ] gravity      |acc| median 1.008 g  (+0.8% vs 1.000 g)
       axes         X +0.012  Y -0.004  Z +1.007
  [ok  ] framing      0 rejected frames

  PASS — sensor is reading correctly. Good to record.
```

Exit status is non-zero on FAIL, so it can gate a script. **The February 2025 oven
session would have failed this** at 1.756 g. If it does fail, run the acceleration
calibration in the WitMotion app with the sensor still, then re-check.

**4. Does rotation track?** Rotate 90° by hand and confirm the angle columns follow.

**5. Then cast.**

## Testing without the sensor

```sh
swift run castr-selftest                                          # unit checks
swift run castr-selftest --emit-fixture fixtures/mine.hex 400     # make a fixture
./.build/debug/castr-collect --replay fixtures/synthetic-cast.hex -o synthetic.csv
```

`fixtures/synthetic-cast.hex` is a 400-frame simulated cast — at rest, one burst of
acceleration and rotation, back to rest. Replay feeds it through the real parser in
20-byte chunks, so it exercises the same incremental path as live BLE. Useful for
developing analysis against a known-shaped file before any real data exists.

Note that `castr-selftest` is a plain executable rather than a `swift test` target:
XCTest ships inside Xcode, not the Command Line Tools, so `swift test` cannot run on a
CLT-only machine.

## Layout

```
Sources/
  CastrCore/       Foundation only — parsing, CSV, synthetic data. No BLE, no UI.
    FrameParser.swift      incremental 0x55/0x61 decoder
    CSVWriter.swift        streaming writer; CSVFormat defines the columns
    SensorReading.swift    the sample type
    SyntheticSource.swift  wire-format generator for tests and fixtures
  CastrBLE/        CoreBluetooth. Builds for macOS and iOS.
    BLEManager.swift       BLESession — scan, connect, stream, off the main thread
    ObservableBLE.swift    SwiftUI wrapper, throttled to 10 Hz
  castr-collect/   The macOS CLI
  castr-selftest/  Test runner and fixture generator
ios/               iOS app sources, parked until Xcode is installed
```

`CSVFormat` in `CastrCore/CSVWriter.swift` is the **single** definition of the output
columns. If downstream analysis needs a different layout, that's the only place to
change.

## What the oven-test data established

Three WitMotion exports (`Oven Test WM.xlsx`, `Oven Test 256hz.xlsx`, and the copy)
answered several open questions. They are **one sensor across two sessions**:
10 Feb 2025 and 1 May 2025. The bracketed identifier differs between them
(`4D7E246CDE8E` vs `E00C94B5AB6C`) but the firmware (`10080.1.13`) and ambient
temperature match, and the identifier is constant within each session — iOS hands out
a per-install CoreBluetooth UUID rather than the sensor's real MAC, so the same unit
appears under a new name after a reinstall or re-pair.

Practical consequence: **don't key anything off the bracketed identifier.** Match on
the `WT901` name prefix instead, which is what `castr-collect` does.

**The rate setting works, and 200 Hz is real.** Measured as rows ÷ elapsed span:

| Configured | Sample 1 | Sample 2 |
|---|---|---|
| RR200 | 198.8 Hz | 194.3 Hz |
| RR100 | 99.6 Hz | 100.5 Hz |
| RR50 | 51.0 Hz | 49.6 Hz |

**The `time` column cannot be used for per-sample timing.** BLE delivers samples in
bursts and the app stamps them on arrival. In the 200 Hz run: only **18.4%** of
timestamps were unique, **6161 of 7551** consecutive deltas were exactly zero, up to
**21 samples shared a single timestamp**, **40 ran backwards**, and gaps reached 720 ms.
Any velocity, jerk or angular-acceleration figure computed against that column is
noise. The *aggregate* rate is trustworthy (198.8 vs 200 Hz over 38 s, 0.6% error), so
a uniform time base reconstructed from the configured rate is the correct approach.
`castr-collect` does this itself — see `FrameParser.feed(_:at:sampleInterval:)`.

**The sensor's accelerometer calibration changed between the two sessions.** Over rows
where the gyro reads zero, a resting sensor must show \|acc\| = 1.000 g:

| Session | Static rows | median \|acc\| | Error |
|---|---|---|---|
| Feb 2025 | 794 | **1.756 g** | **+73%** |
| May 2025 | 5149 | 1.025 g | +2% |

Same unit, same firmware. The February figure is consistent across all 18 test sheets,
so it wasn't a transient — that session's acceleration data is unusable in absolute
terms. By May it was healthy. The most likely explanation is that an acceleration
calibration was run in the WitMotion app in between; whatever the cause, the good state
is the more recent one.

This data can't decompose the February error into scale versus zero offset: the oven
door pivots about a single hinge, so every static orientation lies on one arc (the Y
axis varies by only 0.019 g across all 794 rows). Both a sphere fit and an in-plane
circle fit come back ill-conditioned, so no bias vector is reported here.

Both sessions are over a year old, so **neither tells you the sensor's state today**.
`castr-collect --check` answers that in 15 seconds — see below.

Also confirmed: timestamps are whole milliseconds (every microsecond field is a
multiple of 1000), so the `.SSS` format here matches; and the real export is **21
columns**, not the 11 originally assumed.

## Mounting

**On the rod, immediately above the cork handle.** This is the fixed position — keep it
consistent, because everything derived from the data depends on it.

What that position measures, and what it doesn't:

- **Rotation rate is location-independent.** Angular velocity is a property of the whole
  rigid rod, identical at every point on it. The gyroscope reads the same whether the
  sensor sits at the handle or the tip — so a mount change cannot fix gyro clipping, and
  ±2000 °/s is a hard ceiling on how fast a stroke can be measured.
- **Acceleration is not.** It scales with distance from the pivot
  (`a = ω×(ω×r) + α×r`), which is exactly why this position is a good choice: the
  3 Aug session peaked at 26% of the ±16 g range where a tip mount would likely have
  saturated.
- **This measures the caster's input, not the rod's output.** The handle is what your
  hand does. The tip path is that input plus rod flex, and flex is not observable from
  here — inferring tip position would require a rod model this project doesn't have.

The reconstruction in `tools/reconstruct.py` fits an effective arm from sensor to pivot.
On the 3 Aug session that came out at **24–31 cm**, consistent across the clean events,
which places the pivot around the wrist. Expect that number to stay stable across
sessions; a large change means the mount moved or the stroke recruited a different joint.

## Sensor protocol notes

Service `FFE5`, notify `FFE4`, write `FFE9`. The streaming frame is 20 bytes:

```
0x55 0x61 <9 × int16 LE: AccXYZ, GyroXYZ, AngleXYZ>
```

Scaling is `raw / 32768 × full-scale`, with full scales of 16 g, 2000 °/s and 180°.
There is **no checksum**, which is why the parser leans on two heuristics instead:
pitch (`AngleY`) must fall within ±90°, and when the following byte has already
arrived it must be the next `0x55` header.

Rate changes are `FF AA 03 <code> 00`, wrapped in an unlock (`FF AA 69 88 B5`) and a
save (`FF AA 00 00 00`) so the setting survives a power cycle.

## macOS permission

CoreBluetooth needs permission, and a bare CLI binary can be denied *silently*. The
build embeds an `Info.plist` into the binary (see the linker flags in `Package.swift`)
so the prompt actually appears. If scanning finds nothing at all, check
System Settings → Privacy & Security → Bluetooth and confirm your terminal app is
listed and enabled.

## Known limitations

- **Only the 0x55/0x61 frame** is decoded — no magnetometer or quaternion. Those need a
  register read on `FFE9`. Nothing downstream consumes them yet.
- **Timestamps are reconstructed**, not from the sensor's clock. Samples in a BLE burst
  are spread backwards from packet arrival at the nominal interval, which makes them
  monotonic and keeps the aggregate rate accurate — but the absolute time of any single
  sample is still only as good as the host clock. Fine for cast duration and
  segmentation; check drift before syncing against separate video.
- **No analysis layer yet.** Column names match the real WitMotion export and the nine
  channels we decode carry real values; the other ten columns are present and blank.
  Turning recordings into per-stroke metrics is the next piece of work, not something
  that exists. The header is UTF-8 and contains `°`, a common cause of header-matching
  failures if a file gets read as latin-1.
- **BLE range** is roughly 10 m, so Mac-tethered collection means the laptop comes
  outside with you. That's what the iOS app is for.

## iOS app

Sources are in `ios/`, unbuildable until Xcode is installed. When it is: create a
SwiftUI app project, add `CastrCore` and `CastrBLE` as local package dependencies rather
than copying the files, and set `Privacy - Bluetooth Always Usage Description` in the
target's Info tab.

Two things to know before relying on the phone in the field. Signing with a **free**
Apple ID expires the app after **7 days** — it stops launching and needs re-deploying
from the Mac; a paid account ($99/yr) extends that to a year. And with no background
modes declared, **locking the screen stops the stream**, so recording needs the app
foregrounded and the display awake.
