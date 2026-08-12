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

Covered by `castr-selftest`. 377 checks pass.

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

| session | caster | casting strokes | alternation breaks |
|---|---|---|---|
| slow1 | Nate | 19 | 1 — the pickup, see below |
| cast2 | Nate | 16 | 0 |
| benchtest1 | Nate | 19 | 0 |
| benchtest2 | Nate | 32 | 0 |
| benchtest3 | Nate | 44 | 0 |
| fish1 | Nate | 48 | 0 |
| nate-updown | Nate | 18 | 0 |
| nate-falsecast | Nate | 20 | 0 |
| **dad-updown** | **Dad** | 18 | 0 |
| **dad-falsecast** | **Dad** | 21 | 0 |
| **sam-updown** | **Sam** | 14 | 0 |
| **sam-falsecast** | **Sam** | 20 | 0 |

**289 casting strokes across twelve sessions and three casters, strictly alternating,
one break.** That break is `slow1` #1, the pickup, which is Z-dominant (83.8° of a 99.9°
arc) while every cast in the session is X-dominant — it is off the casting plane, so its
projection onto the casting axis carries no meaning. This is the strongest result in the
project and the thing the classifier should be built on.

**It generalises to casters it has never seen.** Dad and Sam were recorded 2026-08-08 on
the same rod and mount, doing counted motions: 10 forward false casts each, and
pick-up-and-lay-down casts until they stopped. 61 casts between them, zero breaks, and
the detector returned exactly the count the motion implies — 10 forwards and 10 backs,
plus the pickup. Every up-down session came back an exact even split (9/9, 9/9, 7/7),
which is itself the proof nothing merged: a merged pair loses a stroke, turning the
count odd, and leaves a survivor with a tiny arc off a long path (§5). Neither appears.

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
Rod load and line release are not observable at the handle — the README says this, and
a controlled experiment now confirms it.

### The experiment

The 2026-08-08 sessions produced a matched pair per caster, which is exactly the
comparison this needed:

- `*-updown.csv` — pick up and lay down with the line fully extended, so **every
  forward stroke is a delivery**
- `*-falsecast.csv` — false casting, so **every forward stroke is not**

Same caster, same rod, same mount, **same 20 ft of line**, minutes apart. Comparing
forward strokes between the two files is therefore a within-caster test of delivery
against false cast with everything else genuinely held still — including line length,
which §4c and `fish1` both show drives arc and tempo. Verdicts use the pooled-spread
rule from `Report.swift`:

| metric | Nate | Dad | Sam |
|---|---|---|---|
| arc | possible +14° | **CLEAR +40°** | **CLEAR −23°** |
| peak rate | within noise | **CLEAR +67 °/s** | **CLEAR −72 °/s** |
| stop decel | within noise | within noise | within noise |
| duration | within noise | possible | within noise |
| stop share | within noise | within noise | possible |
| peak accel | within noise | within noise | possible |

**No metric separates the two consistently.** Arc and peak rate differ *clearly* — and
in **opposite directions between casters**. Dad opens up and accelerates into a
delivery; Sam shortens and slows down. That is technique, not physics. A threshold on
either would need per-caster calibration and would still be detecting the caster's
habit rather than the delivery.

One footnote worth keeping: stop deceleration came out lower for the delivery in all
three casters (−309, −260, −236 °/s²). Three-for-three on sign, but every one sits
inside the pooled spread, so it is not evidence. It is the single direction worth
re-testing if more casters turn up.

### Earlier evidence, consistent with the above

In `benchtest1` the prototype classifier confidently labelled #20 as a delivery. There
was no delivery in that session; it was continuous false casting that stopped. Every
backup heuristic fails the same way — #20 is also the fastest stroke (887 °/s), also
the last, also followed by quiet.

A follow-through test (rod attitude after the last cast vs. between casts) was
inconclusive: `cast2` held ±3° between casts then settled **27°** away, a real
follow-through; `benchtest1` had a between-cast spread of **±74°**, no still moments at
that tempo and so no baseline; `slow1` ended 0.9 s after the last cast, no data at all.

**Resolution: tag the delivery.** One key per sequence, solo-friendly, and it fills the
classifier's only real gap. This is now a measured conclusion rather than an assumption,
so Stage 4 should take the delivery from the tag and not attempt to infer it.

### The consolation prize: free labelled data

A pick-up-and-lay-down session labels itself. Every stroke is a pickup or a delivery by
construction, alternating. The three `*-updown` sessions therefore provide **25 known
deliveries and 25 known pickups** with no tagging, no reaction-lag problem, and no
dependence on the broken §4a matcher. That is ground truth for the two classes that are
hardest to obtain, and it should be the backbone of Stage 5's validation set.

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

Session CSVs are in `Sessions/`. Sidecars are `<name>.events.csv` alongside them.

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

### Three-caster set, 2026-08-08

Same rod, same mount, one afternoon, and **roughly 20 ft of line out the tip for every
session** — up-downs and false casts alike. Counted motions, so the expected stroke
count is known in advance (§2). Recorded with `--no-tags` on the up-downs; no key was
pressed on the false casts, so no sidecars exist.

Line length being constant across all six is what makes the `-updown` / `-falsecast`
pairing in §3 a controlled experiment rather than a confounded one. It also puts this
set on the same footing as `benchtest3`, which was Nate at 20 ft on 2026-08-04.

| session | samples | dur | rate | strokes | casts | taps | what it is |
|---|---|---|---|---|---|---|---|
| `nate-updown` | 8,575 | 43 s | 198 Hz | 18 | 18 | — | pick up and lay down, line fully extended. **Every stroke is a pickup or a delivery.** |
| `dad-updown` | 6,759 | 34 s | 198 Hz | 19 | 18 | — | as above, Dad |
| `sam-updown` | 6,838 | 35 s | 198 Hz | 14 | 14 | — | as above, Sam. 7 cycles, not 10 — no set count was agreed. |
| `nate-falsecast` | 6,007 | 30 s | 197 Hz | 21 | 20 | — | 10 forward false casts + pickup |
| `dad-falsecast` | 4,543 | 23 s | 197 Hz | 21 | 20 | — | as above, Dad |
| `sam-falsecast` | 4,871 | 25 s | 198 Hz | 20 | 20 | — | as above, Sam |

The `-updown` / `-falsecast` pair per caster is the matched comparison §3 rests on.

**Still not captured:** casting experience per person. Sam's arcs run 24% wider than the
other two (§6 below), and without knowing whether that is a practised caster or a
first-timer there is no way to tell technique from inexperience. Worth asking before
these sessions are used for anything skill-related.

"Casts" counts strokes at or above a **relative** arc threshold — half the median arc of
the largest third of the session. §4c rules out a constant.

All recent sessions are healthy hardware-wise: `benchtest1` measured 1.021 g at rest,
no clipping (peak 7.15 g of 16, 887 °/s of 2000), 99.6% unique timestamps, zero
negative deltas. The reconstructed time base is working — the WitMotion app's own
export managed 18.4% unique with 40 backwards.

**Caveat on the whole corpus:** ~~one caster~~ three casters as of 2026-08-08, but still
**one rod and one mount orientation**. Caster generalisation is now tested (§2); rod and
mount are not.

Caster differences are real and worth remembering before any threshold is fitted. On the
same rod and the same counted motion, mean false-cast arc was 114° for Nate, 114° for
Dad and **141° for Sam** — whose minimum, 128°, is above both of their means.

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
   *every* stroke. Still the validation set for the false-cast labels; Solo tagging of
   all four labels has already been shown not to work (`benchtest1`). Less urgent than
   it was — the `*-updown` sessions already supply 25 labelled pickups and 25 labelled
   deliveries for free (§3), so what is missing is ground truth for *false back* versus
   *false forward*.
3. ~~Second caster~~ — **done 2026-08-08.** Dad and Sam, 61 casts, zero alternation
   breaks (§2). The finding generalises across casters.
4. Deliberate bad casts — tailing loops, breaking the wrist, creep. Needed eventually
   for diagnosis features.
5. **Different rod** — now the largest untested variable, since caster is covered and
   everything in the corpus is one rod. Action and length change tempo and load.

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

**Settled 2026-08-08, so stop revisiting it:** delivery detection from the handle. §3
now has a controlled within-caster experiment across three people, and there is no
consistent signal. Stage 4 takes the delivery from the tag. The corresponding gain is
that `*-updown` sessions are self-labelling — 25 pickups and 25 deliveries, free.

---

## 10. Repeatability of stopping points, drive and plane

Added 2026-08-11. Three things a caster repeats that the coefficient-of-variation
table could not speak for, because they are **directions rather than sizes**: where
the rod stops, how it is driven there, and the plane it travels in. A CV about a mean
direction is meaningless — the mean deviation is near zero by construction — so these
report degrees, in `AngularSpread`, and the verdict bands are separate.

**Casting plane.** Each cast's own rotation axis against the session's arc-weighted
mean, sign-folded so a back cast and the forward cast after it count as the same
plane rather than 180° apart. Mount-independent: nothing here refers to a sensor axis.

**Stopping points.** The rod's attitude at the stop, read off gravity — at the stop
the rod is momentarily still and the accelerometer gives up-in-the-body-frame with
nothing integrated. Two measured corrections went into it:

- *The still moment is not the stop.* Read as-is, it sat a median 8.0° from the burst
  reconstruction's attitude at the stop across the corpus. The hand keeps moving after
  the rod has stopped. The reading is now carried back to the stop across the gyro,
  a fraction of a second of short-baseline integration bounded at 90° of transport.
- *A lone still-looking sample is not a window.* Abandoning the search at the first
  one cost four of the parity fixture's seven strokes their stopping point. A short
  run is now skipped rather than treated as a refusal. Corpus coverage went from
  4/48 to 11/48 on `fish1` and 12/14 to 14/14 on `nathan-updown-2`.

The search also stops at 60 °/s — the rate that opens a stroke. Without that it runs
past the *next* cast and reports that one's quiet as this one's stopping point.

**Drive shape.** Each cast's rate curve resampled to 16 points and divided by its own
peak, compared against the group's average curve. Size and length are already in arc,
duration and peak rate; what is left is shape.

Stops and drive shape are split by direction (`castingFrame`, the small version of
Stage 2) because a back cast and a forward cast stop in different places and are
driven differently. Which group is which is still not in the data.

### What the corpus says

All three are measured over **casts only** — half the median arc of the largest third,
§6's relative rule, now implemented as `SessionStats.casts`. That mattered: including
lifts and re-positions put `fish1`'s plane spread at 46.6° and `benchtest3`'s at 26.6°.
Restricted to casts they read 10.2° and 12.2°.

| session | casts | stops read | plane sd | drive shape |
|---|---|---|---|---|
| `dad-updown` | 18 | 13 | **4.8°** | 93% / 87% |
| `sam-falsecast` | 20 | 1 | 5.3° | 92% / 89% |
| `sam-updown` | 14 | 14 | 6.3° | 85% / 88% |
| `cast2` | 16 | 7 | 6.4° | 83% / 79% |
| `dad-falsecast` | 20 | 1 | 7.2° | 92% / 88% |
| `nate-updown` | 18 | 18 | 7.9° | 87% / 93% |
| `nathan-updown-2` | 14 | 14 | 8.9° | 84% / 87% |
| `nate-falsecast` | 20 | 10 | 10.1° | 80% / 80% |
| `fish1` | 48 | 11 | 10.2° | 78% / 80% |
| `benchtest2` | 32 | 18 | 10.7° | 80% / 84% |
| `benchtest3` | 44 | 21 | 12.2° | 78% / 79% |
| `test-updown` | 16 | 15 | 12.4° | 86% / 84% |
| `benchtest1` | 19 | 18 | 14.6° | 83% / 81% |
| `slow1` | 19 | 6 | **20.2°** | 80% / 81% |

Plane spread runs 4.8–20.2° and stopping points 3.6–15.4°, which is where the verdict
bands sit (5 / 10 / 15). Two independent checks that the plane figure measures what it
claims: **the pickup is the worst cast** in `benchtest1` (59.6°, #1) and `slow1`
(82.1°, #1), which §4 already found by another route; and in compare mode Nate's 10.1°
against Sam's 5.3° is visible in the overhead drawings as a fanned path against a
tight one.

### Where it refuses, and why that is the finding

**Continuous false casting has no measurable stopping point.** `sam-falsecast` reads
1 of 20, `dad-falsecast` 1 of 20. The rod is turned around before it has settled, so
there is no still moment and gravity cannot be read. This is not a threshold to be
loosened:

- Relaxing the acceleration bound is wrong outright — where those strokes slow, the
  handle is 0.2–0.6 g off gravity. That is hand movement, not attitude.
- Subtracting the modelled dynamic acceleration doesn't rescue it either. At the stop
  the centripetal term vanishes but the tangential term is at its largest, and the
  rigid-arm model's residual on real casting is 0.48–0.65, so half of several g of
  tangential acceleration stays in the answer.
- **The reconstruction cannot stand in for it.** It has an attitude for every sample
  in a grounded burst, which would cover nearly the whole corpus — but measured
  against the gravity reading it sits a **median 7.3° out, 20° at the ninth decile**,
  with no trend in elapsed time (r = −0.04). That is gyro scale error over a burst's
  whole integrated path, and it is larger than the 3.6–15.4° spread the figure exists
  to measure. So the reconstruction's `stopUpBody` is computed and cross-checked
  against Swift on the fixture by `verify-reconstruction.js` — where the two agree to
  2.0° — and deliberately not reported.

So the honest answer is a dash and a sentence telling the caster that a pause between
casts is what makes the measurement possible. Same discipline as the ten blank CSV
columns and the refused tip path.

### What this closes and opens

Closes the elevation half of **Stage 1** — rod attitude at a still moment, optional
and blank when there is no still window, exactly as that stage specified. `restBefore`
/`restAfter` are still open. Delivers the axis half of **Stage 2** as `castingFrame`;
the mount-orientation test in §8.1 is still what would prove the mount-independence
claim, and is still unrun.
