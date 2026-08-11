# Calibration protocol

What runs before data collection, why, and which parts are real today.

Run it with:

```sh
cast calibrate          # mount offset — start of every session, and after any remount
cast profile <person>   # per-person reference measurements — once, not per session
```

`CAPTURE.md` is the recording protocol; this is what happens before it. `PLAN.md` §7
Stage 2 is the analysis this feeds.

---

## Provenance, read this first

This document consolidates three drafts: `CastR_Calibration_Protocol.md` and two identical
copies of `CastR_Addendum6_HeightArcCalibration.md`. Those drafts were written against a
version of CastR that **does not exist in this repository**. They refer to `calibrate.js`,
`calibrateMount()`, `castr-collect --calibrate`, `CASTR_HANDOFF.md`,
`CastR_RodTipPath_Addendum.md`, a User Profile store, and a tiered-confidence rod/line
model. None of those are here. Addendum 6 in particular opens by saying body height and arm
length are "already captured" — they are not captured anywhere.

Three substantive corrections are folded in below and recorded in §5. The drafts are kept
for provenance but **this file is the one to follow**.

---

## 1. Level 0 — sensor health *(exists, runs today)*

`StaticCheck` on a 15 s still window: does the sensor still read 1.000 g at rest, was it
actually still, did any frames get rejected. `cast` already refuses to record if this
fails, and `cast check` runs it alone.

This is not mount calibration. It answers "is the sensor lying about magnitude", not "how
is the housing sitting on the rod".

---

## 2. Level 1 — mount offset *(capture runs today, solver is not written)*

The housing sits a few degrees off the rod's true centerline, and nothing downstream knows
it. A short sequence of held positions, with known relationships to the rod's axes, pins
that offset down.

### The sequence

One continuous recording, about 30 seconds, all of it held in the hand — nothing gets laid
down on wet grass. `cast calibrate` counts the time and tells you when to move.

| | | |
|---|---|---|
| 0 | **connection check** | before any timing starts |
| 1 | rod down at your side, arm hanging, rod lined up along the arm | hold 5 s |
| 2 | swing up | measured, not discarded |
| 3 | arm straight up, rod tip at the sky | hold 5 s |
| 4 | bring the rod down to point forward | |
| 5 | arm out, rod pointing straight ahead and level | hold 5 s |

Step 0 exists because a slow BLE connect would otherwise eat a hold window silently. The
recorder is started, data is confirmed flowing and reading ~1.000 g, and only then does
the first hold begin.

### What each hold is worth, which is not equal

**Down and up are antiparallel.** In both, the rod's long axis is vertical, so gravity
runs *along* the blank — in opposite senses, but along the same line. Two antiparallel
vectors constrain no more attitude than one does. That pair is a **consistency check**,
not a source of mount information: if they don't come back ~180° apart, the rod wasn't
lined up along the arm or the arm didn't finish upright.

**The forward hold is the one that carries the clocking.** It is the only pose with
gravity running *across* the rod rather than along it, so a housing rotated by φ about the
blank rotates the measured vector by φ. Everything §5.1 says about why clocking is
observable applies to this pose specifically. A sloppy forward hold costs the whole
calibration, which is why it is gated hardest.

**The swings are kept.** Steps 2 and 4 are rotations about the shoulder with the rod at a
known-ish radius, which is the same fit `reconstruct.js` already performs per burst. Their
row spans are recorded in the JSON so they can be used later; nothing consumes them yet.
Note that the arm they measure belongs to whoever performed the calibration, not to
whoever casts afterwards — the per-person number still comes from §3.

### What `cast calibrate` does now

Records the whole sequence to `calibration/<timestamp>-sequence.csv`, pulls the three
still windows out of it by row range, and gates each one.

Stillness is judged on the gyro **mean**, not the peak that `StaticCheck` uses, and the
thresholds are looser: 5 °/s warns, 12 °/s fails. This is not a second definition of
"still" — it is the same quantity measured for a different physical situation. A pose held
in the hand cannot meet the thresholds a sensor lying on a table can, and what actually
corrupts a 5 s gravity average is sustained drift rather than a momentary twitch. Judging
a handheld pose by the table thresholds would reject every valid capture.

It then checks the geometry — down→up ~180°, up→forward ~90° — and writes
`calibration/<timestamp>.json` with the three mean gravity vectors, the row spans of both
holds and swings, the angles, and a verdict. `current.json` is repointed **only on a
pass**, which is what stops a failed calibration from satisfying the pre-recording gate.

**It does not solve for the offset.** That is a `CastrCore` job — `MountCalibration.swift`,
TRIAD off the stored vectors, covered in `castr-selftest` — and it is not written.

**Capture the sequence anyway.** It is thirty seconds, and it is the only thing that makes
a session retroactively correctable once the solver lands. A session recorded without it
can never be re-referenced. This is the same reasoning as `CAPTURE.md`'s "press `4`
anyway" — the raw observation is cheap and unrecoverable, the processing can come later.

### Why this matters more than it looks

`CAPTURE.md` demands the sensor go on in the *same rotational orientation* every time, and
`PLAN.md` closes §6 with the caveat that the whole corpus is "one rod and one mount
orientation". A working mount solve is what retires that constraint. §8's mount-orientation
test — remount rotated 90°, repeat a short sequence — is the direct check, and with the sequence
captured every session it becomes a five-minute experiment.

---

## 3. Level 2 — per-person reference *(capture runs today, derivation deliberately not)*

Once per person, not per session. These normalise across bodies; they do not correct the
sensor and they never feed `calibrateMount()`.

### Shoulder sweep

**Casting arm hanging straight down, rod aligned with the arm, sensor mounted as normal.
Raise the rod straight out in front to shoulder height — a clean ~90° single-joint sweep —
then hold still.**

`cast profile <person>` records this to `calibration/profile-<person>-sweep.csv`. Feed it
to the browser analyser's reconstruction, which already fits a pivot-to-sensor radius per
burst and already refuses to answer when the model doesn't fit — `reconstruct.js` returns
`implausible arm`, `model does not fit`, `singular` or `too slow` rather than a number it
can't stand behind.

Be exact about what this is: **shoulder-to-sensor distance**, not "arm length". Real
casting pivots at shoulder, elbow and wrist together, and the blend shifts by cast type.
Store it under that name. Its value is that it is a known single-joint rotation, so it
tells you whether the radius fit recovers a sane number *before* you trust it on real
casting.

### Body height

Typed in, no sensor. Recorded so that a taller caster's naturally larger swing radius can
be normalised out instead of being scored as technique.

### What is deliberately NOT derived

Addendum 6 proposes computing `shoulder_pivot_height` and `casting_ready_hand_height` at
profile-save time to anchor the arc overlay to the ground. `cast profile` stores the two
inputs and **stops there**, for the reasons in §5.2 and §5.3: the published formula is
wrong, and even corrected it is a population average entering a pipeline whose defining
discipline is refusing to invent unobservables.

If it is later built, the conditions are:

- It anchors a **display overlay only**. It must never reach a metric, a threshold or the
  JSON that `castr-analyze` emits.
- It is emitted **optional and blank** when height is unknown — the same discipline as the
  ten blank CSV columns and the optional elevation field in `PLAN.md` Stage 1.
- It is labelled as derived from a population average, not measured.

---

## 4. Cadence

| | when |
|---|---|
| Sensor health (`cast check`, and automatically inside `cast`) | every session, and after any remount |
| Mount sequence (`cast calibrate`) | start of every session, and after any remount |
| Profile (`cast profile <person>`) | once per person |

---

## 5. Corrections to the source drafts

### 5.1 `CastR_Calibration_Protocol.md` contradicts itself on clocking — the optimistic half is right

The opening says rotation about the rod's long axis "does not fix... Gravity can't see that
in either pose below". The later section says two poses "fix all three" degrees of freedom
via TRIAD. **Both cannot be true, and the TRIAD section is the correct one.**

In any pose with the rod vertical gravity runs along the rod axis, so clocking is
genuinely invisible there — that half is right. But in a pose with the rod **horizontal**,
gravity is perpendicular to the rod axis, so a housing clocked by φ about the blank
rotates the measured gravity vector by φ. Such a pose observes clocking directly. That is
precisely why a pair is well-conditioned and why the draft's own TRIAD paragraph is
correct. In the sequence above it is the **forward** hold that plays this role.

This is not a footnote. If clocking were unobservable, mount calibration could never retire
`CAPTURE.md`'s same-orientation rule, and the corpus would stay locked to one mount forever.
It is observable, and the rule can go once the solver ships.

The genuine limitation is mechanical, and the draft states it well: if the housing can spin
freely inside its clamp *during* a cast, no amount of calibration helps. That is a fit
problem.

### 5.2 Addendum 6 §4 subtracts the wrong limb segment

It gives:

```
casting_ready_hand_height ≈ shoulder_height − (forearm_length × sin θ)     θ = 90° default
                          ≈ shoulder_height − forearm_length
```

Stand up and check it. Upper arm hanging at your side, elbow at ~90°, forearm horizontal:
your hand is at **elbow** height, and the elbow sits one **upper-arm** length below the
shoulder. The forearm, being horizontal, contributes **zero** vertical drop — yet the
formula gives it its maximum contribution at exactly that angle, because `sin` is being
applied to an angle measured from the wrong reference. The segment is wrong and the trig
is inverted.

The ratio is off as well. Drillis & Contini put forearm at 0.146 H against a
shoulder-to-hand-centre arm of about 0.386 H — a ratio near **0.38**, not the 0.44 quoted.

Corrected, using one ratio instead of two and needing no measured arm length at all:

```
upper_arm_length      ≈ 0.186 × H
hand_height_at_ready  ≈ 0.82 H − 0.186 H  =  0.634 × H
```

For a 5'10" caster the draft's formula lands ~7 cm high, and the error scales with height —
which is self-defeating, since normalising across heights is the entire point.

Dropping measured arm length from this calculation is a feature. Shoulder-to-sensor
distance is the right input for the **radius** in `reconstruct.js`; borrowing it for a
height estimate lends the result a precision it does not have.

### 5.3 The premise "no new data required" is false here

Addendum 6 states body height and arm length are "already captured". In this repository
neither exists — there is no user profile of any kind, and `PLAN.md` §6 lists casting
experience per person as a known, still-open gap in the corpus. The addendum is not a pure
computation over existing data; it needs the collection step in §3 built first, which is
what `cast profile` now does.

The framing that *is* right, and worth keeping: this is not a new sensing problem. Nothing
here asks the IMU for absolute position or elevation, and the single- versus
double-integration boundary in `README.md` stays exactly where it is.

### 5.4 Housekeeping

`CastR_Addendum6_HeightArcCalibration copy.md` is byte-identical to
`CastR_Addendum6_HeightArcCalibration.md`. Delete one.

---

## 6. To build next, in order

1. **`MountCalibration.swift`** in `CastrCore` — TRIAD from the two stored pose vectors,
   returning an optional offset that is `nil` with a reason when the poses are too close
   together or too jittery. Tests in `castr-selftest` against synthetic poses with a known
   injected offset.
2. **Apply it in `StrokeAnalysis`** — rotate readings into rod frame before segmentation.
   This is `PLAN.md` Stage 2's "mount-independent signed arc" arriving by measurement
   rather than by assuming the mount never moved.
3. **Run `PLAN.md` §8 test 1** — remount rotated 90°, short sequence, confirm the corrected
   axes match the un-rotated session. That is the experiment that says whether any of this
   works.
