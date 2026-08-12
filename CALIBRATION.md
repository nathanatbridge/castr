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
| 1 | arm straight up, rod tip at the sky | hold 5 s |
| 2 | bring it down to point forward | measured, not discarded |
| 3 | arm out in front, rod level and straight ahead | hold 5 s |
| 4 | raise it back up to vertical | measured, not discarded |
| 5 | arm straight up, rod tip at the sky **again** | hold 5 s |

Step 0 exists because a slow BLE connect would otherwise eat a hold window silently.

**Poses 1 and 5 are the same pose.** That is the point, and it is the third version of this
sequence. The history is worth keeping, because both earlier versions failed in ways that
only showed up outdoors.

**Version one asked for a tip-down hold** opposite the tip-up one, to average two readings
from opposite ends. A 9 ft rod cannot be pointed at the ground — with the grip at hip height
the tip would be a metre and a half underground — so a caster asked for it holds the rod
somewhere near horizontal instead. Three captures on 2026-08-11 show it plainly: the "down"
hold came back **10–14° from the *forward* hold** rather than 180° from the up hold, every
time. The pose was impossible, so it silently became a second horizontal.

**Version two took the axis from the one vertical hold and checked it against a level hold**,
on the reasoning that a level rod must read square to its own axis. True — but that check
cannot tell a tilted axis from a tilted level hold. It measures the two together. The
22-07-29 capture was refused on a side hold 12.9° out of level while its forward hold said
the very same axis was good to **2.5°**. A check that rejects a good measurement because a
*different* pose was sloppy is not an error bar, and in practice it made the calibration
feel impossible to pass.

**Version three measures the axis twice with the same pose.** The disagreement between the
two tip-at-sky holds is the error bar, and it measures the axis alone. Pointing a rod at the
sky is also the easiest pose to repeat accurately — you can sight along the blank against
the sky — and across four separate captures that night it repeated to between 3.4° and 9.2°,
which is 15–40 cm at the tip before any averaging. Two holds inside one 30-second sequence,
without setting the rod down in between, should do better than that.

### What each hold is worth, which is not equal

**The two vertical holds are the measurement.** The axis is their mean; half their
disagreement is the error bar. Nothing else in the sequence constrains the axis.

**The level hold is for the clocking, and for a smell test.** Everything §5.1 says about why
clocking is observable applies to a level pose: gravity runs across the rod rather than
along it, so a housing rotated by φ about the blank rotates the measured vector by φ. Its
squareness to the axis is reported — `levelOffSquareDeg` — and **never gates anything**, for
the reason version two failed.

**The gate is 20° between the vertical holds**, which is loose on purpose. Past that, one of
them was not vertical, which is a different thing from being a few degrees off.

**One error nothing here can see.** If both vertical holds lean the same way, they agree
perfectly and are both wrong by the lean. The error bar is a **floor on the error, not a
bound on it**. No pose fixes this, so it is stated rather than solved, and asserted in both
`castr-selftest` and `verify-reconstruction.js` so nobody later mistakes a clean bar for a
clean axis.

### What `cast calibrate` does now

Records the whole sequence to `calibration/<timestamp>-sequence.csv`, pulls the three
still windows out of it by row range, and gates each one.

Stillness is judged on the gyro **mean**, not the peak that `StaticCheck` uses, and the
thresholds are looser: 5 °/s warns, 12 °/s fails. This is not a second definition of
"still" — it is the same quantity measured for a different physical situation. A pose held
in the hand cannot meet the thresholds a sensor lying on a table can, and what actually
corrupts a 5 s gravity average is sustained drift rather than a momentary twitch. Judging
a handheld pose by the table thresholds would reject every valid capture.

It then measures the axis from the two vertical holds and writes
`calibration/<timestamp>.json` with the three mean gravity vectors, the row spans of both
holds and swings, the angles, the solved `rodAxis`, and a verdict. `current.json` is
repointed **only on a pass**, which is what stops a failed calibration from satisfying the
pre-recording gate.

**It solves the rod axis and reports it.** `rodAxis` in the JSON carries the butt-to-tip
direction, `errorDeg` (half the spread between the vertical holds), `spreadDeg`, and
`levelOffSquareDeg` for the smell test. The browser re-solves it from the stored hold vectors rather than
reading this field — `MountCalibration.swift` is the authority and `reconstruct.js` is
checked against it — so treat the shell's copy as the field verdict it is. All three agree
to seven decimal places, which `verify-reconstruction.js` and the fixture keep true.

**It does not solve for the clocking.** That is the other half of `MountCalibration.swift`
— TRIAD off the down/up and forward vectors — and it is not written. The `solved` flag in
the JSON refers to that, not to `rodAxis`.

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

### Shoulder sweep — removed, and where it went

`cast profile` used to capture a ~90° single-joint shoulder sweep of its own. It no longer
does, because `cast calibrate` steps 2 and 4 **are** that motion: step 2 swings the rod
from hanging at the side to straight overhead, step 4 brings it down to level in front,
both rotations about the shoulder with the rod at the same radius. Capturing it a second
time measured one thing two ways and added a minute to a per-person setup that is otherwise
three typed answers.

The swing spans are already recorded in the calibration JSON under `swings`. Nothing
consumed the profile sweep; it was written and never read.

**To get the number:** drop `calibration/<stamp>-sequence.csv` into the browser analyser
like any session. The swings segment as strokes and the burst table reports the fitted arm
in centimetres, with the same refusals as everywhere else — `implausible arm`, `model does
not fit`, `singular` or `too slow` rather than a number it cannot stand behind. `cast
calibrate` prints the path to that file for exactly this reason.

It is a manual step at the laptop and deliberately so. The lever-arm solve lives only in
`reconstruct.js`; giving `cast` its own copy would mean a second implementation of the fit
to keep in parity forever, which is the drift the rest of this project spends effort
avoiding. Nothing consumes shoulder-to-sensor yet, so that trade is not worth making until
something does.

Be exact about what this measures either way: **shoulder-to-sensor distance**, not "arm
length". Real casting pivots at shoulder, elbow and wrist together, and the blend shifts by
cast type.

**What the removal costs, stated plainly.** The calibration swings belong to whoever held
the rod during calibration, not to whoever casts afterwards — §2 already said this. For one
person working alone, calibrate and cast, they are the same arm and nothing is lost. For a
session like the three-caster set of 2026-08-08, where one person calibrates and others
cast, there is now no per-person arm measurement at all. If that case comes back and the
number turns out to matter, the answer is a calibration per caster rather than a second
capture in the profile.

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

1. **`MountCalibration.swift`** in `CastrCore` — ~~the rod axis~~ **done**: solved from the
   down/up holds, refused with the measured disagreement, 36 checks in `castr-selftest`
   against synthetic poses, mirrored in `reconstruct.js` and held to Swift's answers by
   `verify-reconstruction.js` off `docs/fixtures/rod-axis.json`. Still to write: **TRIAD
   for the clocking**, from the forward hold, in the same file — returning an optional
   offset that is `nil` with a reason when the poses are too close together or too jittery.
2. **Apply it in `StrokeAnalysis`** — rotate readings into rod frame before segmentation.
   This is `PLAN.md` Stage 2's "mount-independent signed arc" arriving by measurement
   rather than by assuming the mount never moved.
3. **Run `PLAN.md` §8 test 1** — remount rotated 90°, short sequence, confirm the corrected
   axes match the un-rotated session. That is the experiment that says whether any of this
   works.
