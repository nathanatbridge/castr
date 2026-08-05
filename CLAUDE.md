# Castr

Motion capture for fly-casting analysis, built around a WitMotion **WT901BLE** IMU
mounted on the rod immediately above the cork handle. Records CSV in WitMotion's own
column format, then turns recordings into per-stroke metrics.

Start with `README.md` for how the thing works and `PLAN.md` for where the work
currently stands.

## Build and test

```sh
swift build
swift run castr-selftest              # 290 checks, no hardware needed
node tools/verify-web-parity.js       # browser analysis must match Swift
```

**There is no `swift test`.** XCTest ships inside Xcode, and this machine has Command
Line Tools only, so `castr-selftest` is a plain executable target instead. Any new
test goes there, registered from `Sources/castr-selftest/main.swift`.

**Xcode is not installed**, so `ios/` cannot be compiled. Those sources are
parse-checked only:

```sh
swiftc -parse ios/ContentView.swift
```

Never claim iOS code is verified. It isn't.

## Layout

```
Sources/
  CastrCore/       Foundation only. No CoreBluetooth, no UI — the testable core.
    FrameParser.swift      incremental 0x55/0x61 decoder
    CSVWriter.swift        streaming writer; CSVFormat defines the columns
    CSVReader.swift        reads Castr and WitMotion CSVs back
    SensorReading.swift    the sample type; shared timestamp parsing
    StrokeAnalysis.swift   segmentation, per-stroke metrics, spread stats
    EventLog.swift         StrokeLabel + the tag sidecar, read and write
    TagMatching.swift      binds taps to strokes; groups strokes by label
  CastrBLE/        CoreBluetooth. Builds for macOS and iOS.
  castr-collect/   macOS CLI recorder. KeyTagger.swift reads single keypresses.
  castr-analyze/   Offline analysis and reporting.
  castr-selftest/  Test runner and fixture generator.
ios/               iOS app sources, parked until Xcode is installed.
docs/              GitHub Pages browser analyser — live, analysis only, no BLE.
tools/             reconstruct.py, verify-web-parity.js
```

## Hard constraints

- **`CSVFormat` is byte-parity with WitMotion's 21-column export.** That parity is why
  recordings drop into existing analysis unchanged. Do not add columns. Anything extra
  goes in a sidecar file — that's why stroke tags live in `<session>.events.csv`.
- **Ten CSV columns are deliberately blank** (magnetometer, quaternion, temperature,
  version, battery). The 0x55/0x61 frame doesn't carry them. Present so name-based
  column selection finds them; never fabricated.
- **Zero third-party dependencies**, and it should stay that way. No CoreML, no
  runtime Python in the pipeline.
- **Timestamps are reconstructed** from the configured rate, not read from the sensor.
  The sensor's own `time` column is unusable per-sample.
- **The frame format has no checksum.** A rising rejected-frame count is the only
  signal that framing broke. Always surface it.
- **The browser analyser ignores tag sidecars.** Label grouping is `castr-analyze` only.

## Conventions

Match the surrounding code. Comments in this project explain *why*, often citing the
specific evidence that forced a decision (a measured figure, a named session file).
Keep that. Don't add narration comments that restate the code.

Prose in the README and CLI help is plain and direct — no marketing register.

## Data

Session CSVs live in the repo root. `PLAN.md` has the full corpus table with what
each session is and what it's good for. `cast1.csv` and `test1.csv` have all-zero
gyro columns and are useless for anything motion-related.
