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
  run back-to-back at tempo; `cast2.csv` #3 ends 5 ms before #4 starts).

**Reversal-aware segmentation** also ships — see §5, which it resolves — along with the
signed net rotation vector §2 is built on.

Covered by `castr-selftest`. 290 checks pass.

---

## 2. The central finding: direction is free, and we were discarding it

`StrokeAnalysis.swift` used to integrate rotation into a net vector and then collapse it
to a magnitude, throwing the sign away:

```swift
let arc = (net[0]*net[0] + net[1]*net[1] + net[2]*net[2]).squareRoot()
```

`arcDeg` still reports that magnitude, but the vector behind it is now kept as
`netRotationDeg`. It cost two lines and it is the whole back/forward discriminator.

A back cast and a forward cast are the same motion in opposite directions. Projecting
the signed rotation onto the session's dominant rotation axis:

| session | casting strokes | alternation breaks |
|---|---|---|
| slow1 | 19 | 1 — the pickup, see below |
| cast2 | 16 | 0 |
| benchtest1 | 19 | 0 |
| benchtest2 | 32 | 0 |
| benchtest3 | 44 | 0 |
| fish1 | 48 | 0 |

**178 casting strokes across six sessions, strictly alternating, one break.** That break
is `slow1` #1, the pickup, which is Z-dominant (83.8° of a 99.9° arc) while every cast
in the session is X-dominant — it is off the casting plane, so its projection onto the
casting axis carries no meaning. This is the strongest result in the project and the
thing the classifier should be built on.

This supersedes an earlier count of 34 strokes over three sessions. The figure was low
because the detector was merging cast pairs — see §5, which is now resolved. Signed
rotation is emitted as `netRotationDeg` on `StrokeMetrics`, so this table can be
reproduced from `castr-analyze --json` rather than a scratch script.

Secondary findings:

- **The pickup separates on its own.** `slow1` #1 and `benchtest1` #1 both came out on
  the **Z** axis while every cast is on **X**, with long durations (1.55 s, 2.39 s) and
  low peak rates. The lift is off the casting plane.
- **Burst structure is obvious.** Within-burst gaps 0.2–2.7 s; between-burst 5–21 s.
- ~~Repositioning rejects cleanly on arc magnitude~~ — **false, and it was the symptom
  that should have exposed §5 earlier.** The "repositioning" of 5–33° in `cast2` and
  `slow1` was not repositioning. Those were back-and-forward cast *pairs* merged into
  one span, whose opposing rotations cancelled to near zero. `cast2` was read as 6 casts
  plus repositioning; it is 16 casts. A near-zero arc over a long, fast span is the
  signature of a merged pair, not of a small movement — `pathDeg` tells them apart and
  was already being computed.

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

Re-measured after the §5 segmentation fix: the lags and the match counts are unchanged.
Splitting merged pairs moves stroke *ends* very little, so this defect is independent of
that one and is still entirely open.

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

## 5. Resolved: the `fish1` anomaly was a detector defect

**`fish1` showed 52 detected strokes but only 5 above 60° arc.** Nothing was wrong with
the session. The detector was merging each back cast with the forward cast that followed
it, and their opposing rotations cancelled.

`fish1` #22 is the clearest case: one "stroke" of 2.02 s containing gyroX peaks of
**+307 °/s at 86.2 s and −383 °/s at 87.2 s** — a back cast and a forward cast — reported
as an arc of **18.9° off a path of 242°**.

Why rate alone could never close these strokes: between the two casts the rate dips below
`exitDPS` (25 °/s) for **0.00–0.13 s**, and `settleTime` requires 0.12 s. At casting
tempo the rod does not stop, so the stroke never ends. `benchtest1` escaped it only
because it was the butt section with no line, which does stop dead.

How widespread it was, over spans containing more than one burst of rotation:

| session | spans | multi-cast spans | share |
|---|---|---|---|
| benchtest1 | 21 | 0 | 0% |
| slow1 | 14 | 2 | 14% |
| cast2 | 11 | 2 | 18% |
| fish1 | 51 | 22 | 43% |
| benchtest3 | 31 | 16 | 52% |
| benchtest2 | 21 | 12 | 57% |

**The three sessions that established §2's original finding were the three least
affected.** The result generalised anyway, but it was measured on the easy cases.

**Fix, shipped:** `StrokeDetector.splitAtReversals` cuts a span wherever the rod turns
around. Bursts of rotation within a span are compared by the angle between their net
rotation vectors. The measure is sharply bimodal — of 68 burst pairs inside merged spans,
**62 sat at 150–180°** (genuine reversals, each burst a 90–130° cast) and the rest at 86°
or below (wobbles of 17–21° inside one stroke). Nothing lands in between, so
`reversalAngleDeg` at 120° has wide margin either side. The burst-size gate
(`minBurstShare`) is relative to the largest burst in the span, not an absolute arc,
because §4c showed no constant survives.

This is why the sign mattered twice over: discarding it did not only cost the
back/forward label, it hid the fact that two strokes had been recorded as one.

---

## 6. Test corpus

Session CSVs are in the repo root. Sidecars are `<name>.events.csv`.

Stroke and cast counts are **post-fix** (§5); the figures in brackets are what the same
sessions read before reversal splitting, kept because most of the earlier analysis in
this document was written against them.

| session | samples | dur | rate | strokes | casts | taps | what it is |
|---|---|---|---|---|---|---|---|
| `cast1` | 5,010 | 101 s | 50 Hz | 0 | 0 | — | **gyro all zero — useless** |
| `test1` | 530 | 11 s | 49 Hz | 0 | 0 | — | **gyro all zero — useless** |
| `slow1` | 2,228 | 45 s | 50 Hz | 19 *(14)* | 19 *(11)* | — | slow casting; Z-axis lift + 18 alternating |
| `cast2` | 8,568 | 44 s | 195 Hz | 16 *(11)* | 16 *(6)* | — | real casting; probable delivery at the end |
| `benchtest1` | 11,615 | 59 s | 198 Hz | 21 *(21)* | 19 *(19)* | 10 | **butt section only**, no line, solo. **No delivery.** The one session unaffected by §5 — it stops dead between casts. Tags are garbage (9× delivery) — solo tagging failed. |
| `benchtest2` | 15,308 | 77 s | 198 Hz | 34 *(21)* | 32 *(9)* | 5 | full rod, no line, multi-sequence, delivery-only tagging |
| `benchtest3` | 20,598 | 104 s | 199 Hz | 49 *(32)* | 44 *(12)* | 5 | full rod, **20 ft line**. Includes at least one deliberate non-delivery stop. |
| `fish1` | 36,848 | 186 s | 198 Hz | 82 *(52)* | 48 *(5)* | 6 | **natural fishing, 15 → 40 ft progressive**. Most realistic session. |

"Casts" counts strokes at or above a **relative** arc threshold — half the median arc of
the largest third of the session. §4c rules out a constant.

All recent sessions are healthy hardware-wise: `benchtest1` measured 1.021 g at rest,
no clipping (peak 7.15 g of 16, 887 °/s of 2000), 99.6% unique timestamps, zero
negative deltas. The reconstructed time base is working — the WitMotion app's own
export managed 18.4% unique with 40 backwards.

**Caveat on the whole corpus:** one caster, one rod, one mount orientation.

---

## 7. Roadmap

**Stage 0 — fix what §4 and §5 found.** *Segmentation is done* — `splitAtReversals`
ships, with the parity fixture extended to cover it. Still open: the two tagging
defects. Delivery binds to a burst; pre-stream taps are held or discarded.

**Stage 1 — stop discarding signal.** *Signed net rotation is done* — `netRotationDeg`
on `StrokeMetrics`, in the JSON, and checked for sign agreement by the parity tool.
Still to add: `restBefore`/`restAfter` gaps, rod elevation from gravity at the still
moments either side. The elevation field must be **optional and emitted blank** when
there is no genuine still window — `cast2` #3→#5 have 0.00 s gaps and the estimate came
back inverted. Same discipline as the ten blank CSV columns.

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

1. ~~Investigate the `fish1` anomaly~~ — done, and fixed. See §5.
2. Fix the two tagging defects (§4a, §4b). Neither was affected by the §5 fix.
3. Finish Stage 1: `restBefore`/`restAfter` and the optional elevation field.
4. Stages 2–3 — session casting frame, then burst segmentation.
5. Stage 4 classifier on top.

**Worth doing early, now that there is far more data than the roadmap assumed:**
§8's mount-orientation test. Stage 2 normalisation is the next real design decision and
that test can invalidate it in five minutes.
