# Stroke identification — state of the work

Where the automatic stroke-identification work stands, what the data has proven,
what it has broken, and what to do next. Read `CLAUDE.md` first for build/test
mechanics.

**Goal:** identify each stroke in a session as pickup / false back / false forward /
delivery, automatically, from the handle-mounted IMU alone.

---

## 1. What exists today

Live **stroke tagging** shipped and works:

- Four keys during `castr-collect` (`1`/`2`/`3`/`4`, or `p`/`b`/`f`/`d`); four
  buttons with haptics in the iOS app (written, never compiled).
- Tags stream to a sidecar `<session>.events.csv` — never into the CSV, which stays
  WitMotion byte-parity. Unbuffered: a tap can't be reconstructed the way a sample
  nearly can. An untagged session leaves no sidecar.
- `castr-analyze` picks the sidecar up automatically, snaps taps to strokes with
  reaction-lag correction, and reports each stroke type against its own kind
  (`BY LABEL` section). `--lag`, `--events`, `--no-events` control it.
- `TagMatcher` corrects for reaction lag and measures distance to each stroke's
  **end**, not its span — see the comment in `TagMatching.swift` for why (strokes
  run back-to-back at tempo; `cast2.csv` #3 ends 6 ms before #4 starts).

Covered by `castr-selftest`. 284 checks pass.

---

## 2. The central finding: direction is free, and we were discarding it

`StrokeAnalysis.swift` integrates rotation into a net vector and then collapses it to
a magnitude, throwing the sign away:

```swift
let arc = (net[0]*net[0] + net[1]*net[1] + net[2]*net[2]).squareRoot()
```

A back cast and a forward cast are the same motion in opposite directions. Recovering
the sign and projecting onto the session's dominant rotation axis:

| session | casting strokes | signs about the session axis |
|---|---|---|
| cast2 | 6 | `+ − + − + −` |
| slow1 | 10 | `+ − + − + − + − + −` |
| benchtest1 | 18 | `− + − + − + − + − + − + − + − + − +` |

**34 casting strokes, strictly alternating, zero exceptions.** This is the strongest
result in the project and the thing the classifier should be built on.

Secondary findings:

- **The pickup separates on its own.** `slow1` #1 and `benchtest1` #1 both came out on
  the **Z** axis while every cast is on **X**, with long durations (1.55 s, 2.39 s) and
  low peak rates. The lift is off the casting plane.
- **Repositioning rejects cleanly** on arc magnitude — real casts were 90–127°,
  repositioning 5–33°, in the three sessions that established the pattern. *(But see
  §4: this threshold has since broken.)*
- **Burst structure is obvious.** Within-burst gaps 0.2–2.7 s; between-burst 5–21 s.

A working prototype classifier exists in Python only — it was scratch work and was not
kept. It did: session axis by total |net| over big strokes → reject small-arc and
off-axis → group into bursts by gap → alternate back/forward from sign → first cast of
burst is pickup, last forward is delivery. It reproduced the table above correctly.

---

## 3. The one thing that cannot be done without tagging: **delivery**

From above the cork grip, "I delivered" and "I stopped false casting" look the same.
Rod load and line release are not observable at the handle — the README says this and
the data confirms it.

Evidence: in `benchtest1` the classifier confidently labelled #20 as a delivery. There
was no delivery in that session; it was continuous false casting that stopped. Every
backup heuristic fails the same way — #20 is also the fastest stroke (887 °/s), also
the last, also followed by quiet.

A follow-through test (rod attitude after the last cast vs. between casts) was
inconclusive:

- `cast2` — between-cast attitude held ±3°, then settled **27°** away. A real
  follow-through; that session probably did end in a delivery.
- `benchtest1` — between-cast spread **±74°**. At that tempo there are no still
  moments, so there is no baseline to measure a settle against.
- `slow1` — session ended 0.9 s after the last cast. No data.

**Resolution: tag only the delivery.** One key per sequence, solo-friendly, and it
fills the classifier's only real gap. `benchtest3` and `fish1` were recorded on that
basis.

---

## 4. What the later sessions broke

All three of these were discovered from real recordings and need code changes, not
more data.

### 4a. Delivery tag windows are far too tight *(defect)*

Measured delivery tap lag:

| session | lag range | matched |
|---|---|---|
| benchtest2 (no line) | 0.45 – 1.74 s | 4 of 5 |
| benchtest3 (20 ft) | **2.03 – 4.15 s** | **0 of 5** |
| fish1 (15→40 ft) | 0.42 – 10.67 s | 2 of 6 |

`TagMatcher.Settings` uses `reactionLag 0.25` + `lookBack 1.0`, i.e. a 1.25 s window.
Wrong model: with line on you are not reacting to the rod stopping, you are waiting
for the line to shoot and land.

**Do not just widen the window** — that degrades false-cast matching. The fix is that a
**delivery tap should bind to a burst, not a stroke.** The delivery is that burst's
last forward cast regardless of how late the key was pressed, which tolerates a
10-second lag. Consider per-label matching strategies generally.

### 4b. Tags can be recorded before the sensor streams *(defect)*

`benchtest2` has a tap at **−19.98 s** and `benchtest3` at **−10.97 s** — keys pressed
during "Scanning…", before the first sample arrived. `Collector.startTagging` opens
the sidecar alongside the CSV, but samples don't begin until BLE connects. These taps
are meaningless and are currently written silently.

Fix: hold or discard taps that precede the first sample, and say so.

### 4c. The 90–127° arc band is dead

`benchtest2`, with **no line at all**, ranges **67–152°**. Arc is neither a clean
cast/not-cast discriminator nor simply a function of line length. Any arc threshold
must become **relative to the session**, not a constant.

---

## 5. Open question, not yet investigated

**`fish1` shows 52 detected strokes but only 5 above 60° arc** — completely unlike every
other session. Could be genuine fishing motion (stripping line, repositioning, walking)
or the detector behaving differently under load. **Understand this before building on
it.** It is the most realistic session in the corpus and the anomaly is unexplained.

---

## 6. Test corpus

Session CSVs are in the repo root. Sidecars are `<name>.events.csv`.

| session | samples | dur | rate | strokes | casts ≥60° | taps | what it is |
|---|---|---|---|---|---|---|---|
| `cast1` | 5,010 | 101 s | 50 Hz | 0 | 0 | — | **gyro all zero — useless** |
| `test1` | 530 | 11 s | 49 Hz | 0 | 0 | — | **gyro all zero — useless** |
| `slow1` | 2,228 | 45 s | 50 Hz | 14 | 11 | — | slow casting; Z-axis lift + 10 alternating |
| `cast2` | 8,568 | 44 s | 195 Hz | 11 | 6 | — | real casting; probable delivery at the end |
| `benchtest1` | 11,615 | 59 s | 198 Hz | 21 | 19 | 10 | **butt section only**, no line, solo. 18 alternating strokes, **no delivery**. Tags are garbage (9× delivery) — solo tagging failed. |
| `benchtest2` | 15,308 | 77 s | 198 Hz | 21 | 9 | 5 | full rod, no line, multi-sequence, delivery-only tagging |
| `benchtest3` | 20,598 | 104 s | 199 Hz | 32 | 12 | 5 | full rod, **20 ft line**. Includes at least one deliberate non-delivery stop. |
| `fish1` | 36,848 | 186 s | 198 Hz | 52 | 5 | 6 | **natural fishing, 15 → 40 ft progressive**. Most realistic session. See §5. |

All recent sessions are healthy hardware-wise: `benchtest1` measured 1.021 g at rest,
no clipping (peak 7.15 g of 16, 887 °/s of 2000), 99.6% unique timestamps, zero
negative deltas. The reconstructed time base is working — the WitMotion app's own
export managed 18.4% unique with 40 backwards.

**Caveat on the whole corpus:** one caster, one rod, one mount orientation.

---

## 7. Roadmap

**Stage 0 — fix what §4 found.** The two tagging defects. Delivery binds to a burst;
pre-stream taps are held or discarded.

**Stage 1 — stop discarding signal.** Add to `StrokeMetrics`: signed net rotation
vector, `restBefore`/`restAfter` gaps, rod elevation from gravity at the still moments
either side. The elevation field must be **optional and emitted blank** when there is
no genuine still window — `cast2` #3→#5 have 0.00 s gaps and the estimate came back
inverted. Same discipline as the ten blank CSV columns.

**Stage 2 — session casting frame.** Principal axis over per-stroke net rotations;
project each stroke onto it for a mount-independent signed arc. Sign anchor: the
pickup goes back. (A 3-second zero pose at session start would be cheap insurance;
decoding quaternions off `FFE9` would make this trivial but is a bigger job.)

**Stage 3 — burst segmentation** above stroke segmentation. Group strokes with gaps
under ~1.5–3 s. Note `benchtest1` had a 5.9 s pause between the lift and the first
cast, which a 3 s threshold wrongly split — tune against the corpus.

**Stage 4 — classify as a grammar.** Reject non-casts on relative arc and axis;
alternate back/forward on sign; pickup from lift-detection plus burst position;
delivery from the tag. Report alternation breaks rather than forcing labels — a break
means a missed stroke or a detector error, and that is diagnostic.

**Stage 5 — validate against human tags.** `--verify-labels`: run the classifier,
compare against the sidecar, print a confusion matrix. This is what turns "looks
right" into a number.

**Stage 6 — learn thresholds** from accumulated labels rather than hand-picking. A
small decision tree emitted as Swift. Only once there is enough data.

---

## 8. Tests still worth running

Not yet done. Ordered by value.

1. **Mount orientation** (~5 min, highest value). Remount the sensor rotated 90° and
   repeat a short sequence. Directly tests whether Stage 2's normalization works. Can
   invalidate a design decision, so worth doing early.
2. **Two-person full tagging.** One careful session with a second person tagging
   *every* stroke. This is the validation set for Stage 5. Solo tagging of all four
   labels has already been shown not to work (`benchtest1`).
3. Second caster — generalization; all current data is one person's mechanics.
4. Deliberate bad casts — tailing loops, breaking the wrist, creep. Needed eventually
   for diagnosis features.
5. Different rod action / length.

---

## 9. Immediate next steps

1. Investigate the `fish1` anomaly (§5).
2. Fix the two tagging defects (§4a, §4b).
3. Full analysis pass across all six usable sessions.
4. Build Stages 1–3 into `CastrCore`, with tests in `castr-selftest`.
5. Stage 4 classifier on top.

**Uncommitted at handoff:** the entire event-tagging feature and these two documents.
See `git status`.
