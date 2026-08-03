# CastR

Motion capture for casting analysis, built around a WitMotion **WT901BLE** IMU.
Replaces the WitMotion app and exports CSV in the column format `cast_analysis.py`
expects.

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
./.build/debug/castr-collect --seconds 20 -o rest.csv    # sensor flat on a table
```

Acceleration should sit near (0, 0, 1) g — magnitude ~1.0 — and gyro near zero. This is
the check that scaling and framing are both right. Rejected frames should be 0.

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
pointing `cast_analysis.py` at a known-shaped file before any real data exists.

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
columns. If `cast_analysis.py` disagrees, that's the only place to change.

## What the oven-test data established

Three WitMotion exports (`Oven Test WM.xlsx`, `Oven Test 256hz.xlsx`, and the copy)
answered several open questions. They cover **two different sensors**:
`WT901BLE67(4D7E246CDE8E)` from 10 Feb 2025 and `WT901BLE67(E00C94B5AB6C)` from
1 May 2025.

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

**One of the two sensors is badly out of calibration.** Over rows where the gyro reads
zero, a resting sensor must show \|acc\| = 1.000 g:

| Sensor | Static rows | median \|acc\| | Error |
|---|---|---|---|
| `4D7E246CDE8E` (Feb) | 794 | **1.756 g** | **+73%** |
| `E00C94B5AB6C` (May) | 5149 | 1.025 g | +2% |

The May sensor is fine. The February one is not, and it's consistent across all 18
test sheets, so it isn't a transient. This data can't say whether it's a scale error or
a zero offset: the oven door pivots about one hinge, so every static orientation lies
on a single arc (the Y axis varies by only 0.019 g across all 794 rows), which is not
enough geometry to solve for a 3-axis bias — both a sphere fit and an in-plane circle
fit come back ill-conditioned. **A six-position test would settle it in two minutes**:
rest the sensor on each face in turn, a few seconds each, and record. That samples all
six directions and makes the bias and scale separable.

Also confirmed: timestamps are whole milliseconds (every microsecond field is a
multiple of 1000), so the `.SSS` format here matches; and the real export is **21
columns**, not the 11 originally assumed.

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
  register read on `FFE9`. `cast_analysis.py` doesn't use them.
- **Timestamps are reconstructed**, not from the sensor's clock. Samples in a BLE burst
  are spread backwards from packet arrival at the nominal interval, which makes them
  monotonic and keeps the aggregate rate accurate — but the absolute time of any single
  sample is still only as good as the host clock. Fine for cast duration and
  segmentation; check drift before syncing against separate video.
- **Column names match the real WitMotion export, but `cast_analysis.py` itself is
  still unseen.** The nine channels we decode carry real values; the other ten columns
  are present and blank. The header is UTF-8 and contains `°`, a common cause of
  header-matching failures if a file gets read as latin-1.
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
