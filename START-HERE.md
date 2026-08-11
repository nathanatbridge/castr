# Start here

Everything needed to pick this project up cold. Written 2026-08-04.

**Project root:** `/Users/nathandorathy/Desktop/Castr` — on the Desktop, not in a
normal code directory.

---

## Read first, in this order

| File | What it gives you |
|---|---|
| `CLAUDE.md` | Auto-loads into a Claude session. Build/test commands, layout, the constraints that are easy to violate. |
| `PLAN.md` | Full state of the stroke-identification work: the 178-cast alternation finding, why delivery can't be auto-detected, the broken assumptions, the corpus table, the six-stage roadmap. |
| `APP-PLAN.md` | Turning the project into an app: web first to settle what a session should say, then native iOS for the field. Runs in parallel with `PLAN.md`, not after it. |
| `README.md` | How the system works — sensor protocol, mounting, bring-up, tagging, analysis. |

---

## Git

- Remote — `https://github.com/nathanatbridge/castr`
- `main` @ `6dc653d`, pushed. The reversal-splitting fix and the doc updates that
  go with it are **uncommitted** on top of it — see `git status`.
- Live GitHub Pages site — `https://nathanatbridge.github.io/castr/`
  (browser analyser: drag-drop a CSV, analysis only, no BLE, ignores tag sidecars)

---

## Data — ~13 MB, **gitignored**, exists only in this folder

| File | Size | What it is |
|---|---|---|
| `fish1.csv` + `.events.csv` | 4.0 MB | Natural fishing, 15 → 40 ft progressive. **Most realistic session.** 48 alternating casts. |
| `benchtest3.csv` + `.events.csv` | 2.3 MB | Full rod, 20 ft line. Includes a deliberate non-delivery stop. 44 casts. |
| `benchtest2.csv` + `.events.csv` | 1.7 MB | Full rod, no line, multi-sequence. 32 casts. |
| `benchtest1.csv` + `.events.csv` | 1.3 MB | Butt section only, no line, solo. 19 casts, no delivery. Tags are garbage. |
| `cast2.csv` | 948 KB | 16 alternating casts; probable real delivery at the end. |
| `slow1.csv` | 248 KB | Slow casting; Z-axis lift + 18 alternating casts. |
| `cast1.csv`, `test1.csv` | — | **Gyro columns all zero. Useless.** |
| `docs/fixtures/strokes.csv` | 145 KB | Tracked in git — synthetic parity fixture, not a recording. |

`*.csv` is gitignored by a deliberate rule in `.gitignore`, with an explicit exception
for the parity fixture. **These recordings are not backed up anywhere.** They cost a
trip outside with a rod and won't reproduce identically — the code can be rewritten,
this data can't.

---

## Key source files

```
Sources/CastrCore/StrokeAnalysis.swift   segmentation + metrics. splitAtReversals is
                                         what stops a back cast and the forward cast
                                         after it being reported as one stroke
Sources/CastrCore/EventLog.swift         StrokeLabel, tag sidecar read/write
Sources/CastrCore/TagMatching.swift      tap → stroke matching, label grouping
Sources/castr-collect/KeyTagger.swift    single-keypress reader, leaves Ctrl-C working
docs/analysis.js                         JS port of the analysis — relevant if moving
                                         toward a real website/app
docs/reconstruct.js                      swing path: side elevation + overhead view, from
                                         orientation times a fitted lever arm
tools/verify-web-parity.js               keeps the Swift and JS analyses in agreement
tools/verify-reconstruction.js           swing path vs the fixture's known arm and bias
tools/reconstruct.py                     the same fit as a standalone CLI tool
```

---

## Commands

```sh
cd /Users/nathandorathy/Desktop/Castr
swift build
swift run castr-selftest              # 290 checks, no hardware needed
node tools/verify-web-parity.js
node tools/verify-reconstruction.js
swiftc -parse ios/ContentView.swift   # the only check available for iOS
```

### Recording a session

```sh
./.build/debug/castr-collect --check     # sensor still, 15s, must read about 1.000 g
./.build/debug/castr-collect -o session.csv --despike --rate 200
```

Tag keys while recording: `1` pickup, `2` false back, `3` false forward, `4` delivery
(or `p`/`b`/`f`/`d`). Solo casting — tag **only** the delivery with `4`.

```sh
swift run castr-analyze session.csv
```

---

## Gotchas that will bite

- **No `swift test`.** Command Line Tools only; XCTest ships inside Xcode. Tests are
  the `castr-selftest` executable.
- **`ios/` has never been compiled.** No Xcode, no iOS SDK. Parse-checked only — never
  claim that code is verified.
- **`CSVFormat` is byte-parity with WitMotion's 21-column export.** Extras go in
  sidecar files, never new columns.
- **Zero third-party dependencies.** Keep it that way — no CoreML, no runtime Python.
- **The frame format has no checksum.** A rising rejected-frame count is the only
  signal that framing broke.
- **A file vanished from this folder** during the 2026-08-04 session
  (`Oven Test WM.xlsx`, recovered from git; cause never identified). The CSVs have no
  such safety net.

---

## Opening prompt for a new Claude session

> Working on Castr at `/Users/nathandorathy/Desktop/Castr`. Read `CLAUDE.md` and
> `PLAN.md` first — they carry the full state. Next up is PLAN.md §9: fix the two
> tagging defects, finish Stage 1, then Stages 2–3.

A saved memory entry (`castr-project`) also points new sessions here, so it should
orient even without the prompt.

---

## Where the work stands

Done: live stroke tagging, sidecar format, lag-corrected tap matching, label-aware
analysis, reversal-aware segmentation, signed net rotation, 290 tests.

The `fish1` anomaly is solved. It was a detector defect, not a property of the session:
back casts and the forward casts after them were being merged into single strokes whose
opposing rotations cancelled. `StrokeDetector.splitAtReversals` fixes it, and the
corpus went from 34 known alternating casts to **178, with one explained break**.
`PLAN.md` §5 has the evidence.

Next, from `PLAN.md` §9:

1. Fix the two tagging defects — delivery taps need to bind to a *burst* not a stroke
   (benchtest3 still matches 0 of 5); taps recorded before the sensor streams must be
   held or discarded. Neither was affected by the segmentation fix.
2. Finish Stage 1 — `restBefore`/`restAfter` gaps and the optional elevation field.
3. Stages 2–3 — session casting frame, then burst segmentation.
4. Stage 4 classifier on top.

Worth doing early: the mount-orientation test in `PLAN.md` §8. Stage 2 is the next real
design decision and five minutes of recording can invalidate it.

The app direction now has its own plan — `APP-PLAN.md`. Web app first to settle what a
session report should say, native iOS after, with Xcode installing in the background
from day one because it is the long pole. It runs alongside the algorithm work rather
than waiting for it.
