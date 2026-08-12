# Rod tip path — plan

Where the rod tip goes during a stroke. Two separate problems wearing one name, and most of
the difficulty comes from not separating them.

Read `CALIBRATION.md` first. The first half of this is a calibration problem, not a sensing
problem.

---

## 0. Provenance

Five drafts arrived after the first version of this plan: `CastR_Analysis_Framework.md`,
`CastR_RodTipPath_Addendum.md`, `CastR_LineLoading_Variables.md`,
`CastR_Addendum3_DataAndNoLinePractice.md`, `CastR_RodTesting_HomeGuide.md`.

Same status as the calibration drafts — written against a CastR that does not exist in this
repository. They assume a rod library, a line database, a phone app, a Training Mode, and
real-time simulation on device. None of those are here. Treat them the way
`CALIBRATION.md` treats its own sources: the physics is worth taking seriously, the
inventory is not. Corrections in §6.

The first version of this plan said flex should not be modelled, because modelling it from
stiffness and line load would be inventing an unobservable. **That was wrong, and
`CastR_RodTesting_HomeGuide.md` is why.** The rod's stiffness and damping are not
unobservables — they are bench-measurable in a garage with a clamp, a bag of pennies and
the sensor already owned. A forward model driven by measured input, parameterised by
measured constants, is not invention. It has to be validated before it is believed, which is
a different objection and is handled in §4.

---

## 1. The architecture: three layers, and they compose

```
tip(t)  =  R(t) · ( r_body + L·û_rod )   +   deflection(t)   +   line reaction
           └──────── Layer 1 ────────┘       └── Layer 2 ──┘     └─ Layer 3 ─┘
           geometry + calibration            driven beam         coupled rod+line
           measured constants                bench-measured      largely unconstrained
```

**Layer 1 — the geometric tip.** Where the tip would be if the blank were rigid. Pure
geometry on top of the reconstruction that already ships.

**Layer 2 — flex.** The blank's own bending response to the base motion. A driven cantilever
whose parameters come from bench tests.

**Layer 3 — line.** The tip-end reaction from line mass and drag. The coupled system.

Three things follow from writing it this way, and they set the whole build order.

**Layer 2 needs Layer 1, and cannot be built first.** A beam model's input is base motion
*expressed in the rod's own frame*, and its output is a deflection *along and across the rod
axis*. Both require `û_rod`. Layer 2 without Layer 1 has no frame to bend in.

**Layer 1 is not merely a stepping stone — for one whole product mode it is the complete
answer.** `CastR_Addendum3` Part C proposes a no-line Fundamentals mode and notes that an
unloaded rod barely flexes, so there is nothing for the tip-path model to reconstruct. Read
the other way round: **in Fundamentals mode Layer 1 is exact.** No flex, no line, geometry
only. The layer that ships first is also the layer that is fully correct for the mode that
needs no equipment beyond the sensor and a rod.

**Each layer is worth less and costs more than the one before it.** Layer 1 is measured
constants and a tape-measure ground truth. Layer 2 is an afternoon of bench testing, a
simulator, and a filmed cast to validate. Layer 3 has no ground truth available at all
without instrumenting the line.

---

## 2. Layer 1 — the geometric tip path

### 2.1 The idea

The reconstruction already puts the sensor at `R(t) · r_body`: pivot at the origin,
orientation integrated from the gyro, `r_body` the lever arm fitted to the acceleration.
The tip sits further out along the same rigid body:

```
tip(t) = R(t) · ( r_body + L · û_rod )
```

`L` is the sensor-to-tip distance, `û_rod` the rod's long axis in the sensor's frame. Both
constants. **No new integration, no new estimator** — the tip is the existing sensor path
with a known offset added before the same rotation is applied.

The term that is 90% of the tip's radius (`L·û_rod`) is measured with a tape measure and a
calibration pose, not fitted. The fitted, uncertain part (`r_body`) stays exactly the size
it always was.

### 2.2 What is already here

Orientation, lever arm, burst grouping, heading rotation, sign anchor and every refusal are
in [docs/reconstruct.js](docs/reconstruct.js), with ground truth in
[tools/verify-reconstruction.js](tools/verify-reconstruction.js). `cast calibrate` already
captures the poses that observe the rod axis. `cast profile` already has a free-text rod
field. The drawing code already renders pivot, arm and sensor.

Three things are missing and only three: `û_rod`, `L`, and — optional, display only — a
ground anchor.

### 2.3 The axis falls out of a calibration that already runs

`cast calibrate` holds the rod tip-down (pose 1) and tip-up (pose 3) and writes the mean
gravity vector for each. In both poses the blank is vertical, so gravity runs *along* the
rod. In the sensor's frame:

```
û_rod = normalise( g_up − g_down )        pointing butt → tip
```

`CALIBRATION.md` §2 calls the down/up pair a consistency check because it carries no
*clocking* information. True — and it is exactly the pair that carries the **axis**, measured
twice, antiparallel, with the existing 180° agreement check as its own error bar.

**The tip projection needs only the easy half of mount calibration.** Rotation about the
blank does not move the tip, so the forward hold — the pose gated hardest, the one that
costs the whole calibration when sloppy — is not needed here. The axis solve is a strict
subset of the TRIAD solver in `CALIBRATION.md` §6 item 1 and ships ahead of the clocking
half.

No capture change. The vectors are already written by a step the cadence already requires.

### 2.4 `L` is typed in, once

`L` = rod length (butt cap to tip) − mount offset (butt cap to housing centre, measured with
the sensor mounted). A 9 ft rod with the housing 30 cm up the handle gives `L ≈ 2.44 m`.

Add to `cast profile`: `rodLengthCm`, `sensorOffsetCm`, `tipFromSensorCm` (derived, blank
when either input is blank). Free-text `rod` stays.

**Where this lives is a real decision.** Rod geometry belongs to the rod, not the person, and
the bench tests in §4 produce a whole parameter set per rod model. The cheap move now is the
person profile; the correct move — and §4 forces it anyway — is
`calibration/rod-<make>-<model>-<length>.json`, with a rod name on the session. Given §4 is
in the plan, **build the rod file now** rather than migrating later.

### 2.5 Error budget, with numbers

Corpus figures: sensor arm 17–28 cm, so ~22 cm typical, against a tip 2.44 m out.

| source | effect on the tip | size |
|---|---|---|
| **Orientation error** (gyro drift, gravity anchor tilt) | rotates the whole path | 1° = **0.4 cm at the sensor, 4.3 cm at the tip** — ~11× amplification |
| **Axis error** `û_rod` | tilts the tip about the sensor | 1° = 4.3 cm. Gated by the down↔up 180° check |
| **`L` error** (tape measure) | uniform scale | ±2 cm on 244 = 0.8%, negligible |
| **`r_body` error**, incl. the ridge-dropped component | rigid translation of the path | ≤ ~30 cm — it moves the path, it does not distort its **shape** |
| **Blank flex** | Layer 1 is simply not modelling this | tens of cm — that is Layer 2 |

Two conclusions.

**Shape errors come from orientation alone.** The arm's uncertainty, including the component
the ridge deliberately drops, enters as a translation, not a distortion. The tip path's
*shape* is better conditioned than the sensor path's, relative to its own size.

**Amplification changes one refusal.** Eleven times is enough that the tip path must be
**refused when `grounded` is false**. The sensor path tolerates a fallback gravity reference
from the quietest single sample, because a few degrees of tilt is a few millimetres there. At
the tip it is centimetres of invented arc height, which is the number a caster would read.
Same principle as the optional elevation field: no still window, no estimate.

### 2.6 What Layer 1 is, and is not

It is the **unloaded, rigid-blank tip**. Label it that in the UI, not "rod tip".

It is still the most useful thing on the page, for a reason worth writing down: tracking,
casting arc, straight-line path and creep are properties of *rod orientation*, and Layer 1 is
orientation rendered at a scale where a caster can see it. An 8° wrist break is 3 cm of
sensor movement and 34 cm at the tip. Layer 1 does not make those metrics newly possible —
`CastR_Analysis_Framework.md` §2 already has them as directly assessable — it makes them
legible.

It does **not** upgrade loop shape. That framework's 🔴 on loop tightness and tailing loops
stands unchanged after Layer 1, because the loop is a flex-and-line phenomenon and Layer 1
is by construction the no-flex answer. Layer 2 is the thing that would move that rating, and
§4 sets out what it costs.

### 2.7 Ground truth — the tip-touch test

**~10 minutes, tape measure, no video.** The gate for everything Layer 1 feeds.

Mark two ground points a measured distance apart (2.00 m is convenient). Sensor mounted,
`cast calibrate` done, no line out. Stand still, touch the tip to A, sweep across and touch
B, hold, sweep back. Five reps.

The touches are findable in the data — stillness at each end, a contact spike — and the
reconstruction must place the tip 2.00 m apart at those instants. Absolute tip-position
ground truth from a tape measure. It stresses exactly the two new unknowns (`û_rod` and `L`)
and nothing else, in the slow unloaded regime where the rigid model is actually true.

*Passes at:* separation within 10 cm across five reps (5%). A failure points at the axis or
the length, and both are independently checkable — the property that makes this test worth
more than a prettier one.

**Fixture:** extend the `castr-selftest` generator with a known rod axis and tip extension;
`verify-reconstruction.js` then asserts tip radius and planarity the way it already asserts
the arm.

---

## 3. Layer 2 — flex

### 3.1 The case for it, stated fairly

A fly rod is a tapered cantilever driven at the base. Given the base motion and the beam's
mass and stiffness distribution, the tip motion is computable. That is standard structural
dynamics, not speculation, and `CastR_RodTipPath_Addendum.md` §2 is right that a
lumped-segment chain (3–6 segments, torsional spring-dampers, RK4) is the practical version.

What makes it admissible in *this* repository is `CastR_RodTesting_HomeGuide.md`: the
parameters are measurable at home. Static deflection under a known load gives the stiffness
distribution; a free-decay test gives natural frequency and damping. Those are measurements,
with error bars, obtained with a clamp and a kitchen scale.

### 3.2 The pivotal experiment, and it is not the simulator

`CastR_RodTesting_HomeGuide.md` §6 proposes an optional Test 3: put the sensor at its normal
handle position and see whether it registers the rod's free oscillation at all.

**Run that first. It is not optional and it is not last.** It decides what Layer 2 can
honestly claim:

- **If the handle sees the rod's dynamics**, some of the flex state is observable in live
  data. The model can be corrected, or at minimum cross-checked, per cast.
- **If the handle sees nothing** — which `CastR_Analysis_Framework.md` §2 predicts when it
  calls the handle "one flex-cycle removed" — then Layer 2 is **open-loop feedforward
  simulation**. Nothing in the session data confirms or refutes the tip path it draws. Every
  session on the same rod with the same base motion produces the same deflection, by
  construction.

That second outcome does not kill Layer 2. Feedforward from measured parameters is a
legitimate estimate. But it is a *different claim* than the rest of this project makes, and it
must be labelled differently: everything else here is refused when the data cannot support
it, and an open-loop simulation can never be refused by the data, because the data never
enters. That asymmetry is the thing to be honest about, in the UI and internally.

Twenty minutes with a clamp and the sensor settles it. It is the highest-value-per-minute
test in this document.

### 3.3 Parameters, and the tier question

`CastR_RodTipPath_Addendum.md` §3 offers three tiers: class-based defaults, own bench
testing, and a user self-calibration "twang test".

An earlier version of this plan said **Tier 2 or nothing** — bench-measured rods only, no
class defaults. That is too strict, and §3.5 sets out the version of Tier 1 that is
defensible: a class default expressed as a **range**, propagated through the model as a band,
with the verdict refused when the band spans conflicting answers. The objection was never to
using published class data; it was to drawing a single confident line from a guess. A band
is not a guess wearing a measurement's clothes — it is the guess, stated at its true width.

What stands from the original objection: **a class default must never be silently
indistinguishable from a measured rod.** The band is what makes it distinguishable, and it
is what gives the caster a reason to bench-test their own rod — measuring collapses the band
to a line.

Tier 3 self-calibration is a genuinely good long-term answer and should be revisited *after*
Tier 2 has validated that the fitting works at all — which is the addendum's own
recommendation, and it is right.

### 3.4 What public rod data actually exists

Checked 2026-08-11.

**The methodology is public and complete.** The Common Cents System — Hanneman, published
2004 in RodMaker — defines IP, ERN, AA and CCF, with the procedure and conversion tables
free at [common-cents.info](https://common-cents.info/). This is the standard to key
everything to. `CastR_RodTesting_HomeGuide.md` is a paraphrase of it, with the errors in §4
below.

**Per-model numbers for production fly rods are sparse.** Blank makers publish some — Batson
publishes IP in grams, AA in degrees and ERN for seven fly blanks in the
[Rainshadow CCS table](https://batsonenterprises.com/rainshadow-rod-blank-ccs-data)
(e.g. `RXXF905-4SS`: IP 131.3 g, AA 71–72°, ERN 6.62). That is real per-model data, but it
is blanks, not finished rods, and seven of them.

**The aggregate database is gone.** [rodcents.org](https://www.rodcents.org/), the CCS
database, currently returns a server configuration error rather than any data. Forum
databases exist on rodbuilding and speypages but are scattered and unverified.

**Yellowstone Angler covers many production rods but publishes pictures, not numbers.**
Their [shootouts](https://www.yellowstoneangler.com/pages/yellowstone-2024-5-weight-fly-rod-shootout)
run a consistent method — rod at ~45°, 3.9 oz hung from the tip top — and the deflection
charts are photographs of deflected rods. Numeric data per rod is overall weight, swing
weight and MOI. The charts are digitisable into a deflection curve, but that is manual work
per rod and their loading is not the CCS 1/3-length criterion, so the numbers are not
directly comparable to a CCS table.

**The Redington Trace is almost certainly not in any published table.** Budget rods are not
what gets shootout coverage or CCS submissions.

Net: the industry has a good standard for measuring this and has published very little data
using it. Which is the argument for §7's R1 — an afternoon with a clamp produces better data
about your own rod than anything available to look up.

### 3.5 The rod-class model, and the one thing to get right

**Do not key class defaults off the manufacturer's action word.** Hanneman's stated reason
for building CCS in the first place was that manufacturer action ratings are not consistent
between brands — "fast" from one maker is not "fast" from another. Keying a physics model
off the least standardised input in the whole system puts the largest error at the very
front of the chain, where everything downstream inherits it.

Key it off the two CCS numbers instead, both of which are physically meaningful to a lumped
model:

| | what it is | what it sets in the model |
|---|---|---|
| **IP** (grains to deflect the tip 1/3 of rod length), or **ERN** | overall stiffness scale | the magnitude of every segment's spring constant |
| **AA** (tip angle at that deflection, degrees) | *where* the bend sits — tip vs through the butt | the stiffness **distribution** along the segments |

AA has a real scale: roughly 59–63° is slow, 66°+ is fast, with published values running to
about 85°. That is the objective version of the action word, and it is the parameter the
user should be entering.

So the rod entry is:

1. **Known CCS numbers** — enter IP/ERN and AA. Band collapses to a line. Bench-measured or
   published, same path.
2. **Known length + line weight + action word only** — map to an (IP, AA) **rectangle**, not
   a point. The action word picks a wide AA range; the line weight picks an IP range.
3. **Nothing known** — no Layer 2 output. Layer 1 still draws.

**Then run the model at the corners of the rectangle and draw the envelope, not a line.**
The verdict rule follows directly:

- Envelope gives the same verdict throughout (straight / convex / concave) → report the
  verdict, and show the band so the uncertainty is visible.
- Envelope spans conflicting verdicts → **refuse**, and say the rod is not characterised
  well enough to call it.

This is the same discipline as the ridge dropping the unobservable arm component and the
reconstruction refusing bursts that are not rigid rotation: state what the data supports,
refuse the rest, and make the refusal informative. It also has a useful property for the
product — the band narrows when the user measures their rod, so the incentive to bench-test
is built into what they see rather than nagged.

The class table itself is a small piece of data — a few rows keyed on (length, line weight,
AA bucket) with IP and AA ranges. Seed it from the Batson fly-blank rows, the CCS
conversion tables, and the Trace's own bench numbers once R1 runs. One measured rod inside a
bucket is worth a lot: it says whether the bucket's range is honest.

### 3.4 Validation is a filmed cast, and there is no substitute

Layer 1 has a tape-measure ground truth because the rigid tip is a geometric claim. Layer 2's
claim is dynamic, and the only thing that measures it is a camera. 240 fps from the side,
metre stick in frame, one rod, a handful of casts, tracked offline.

Until that exists, **Layer 2 draws nothing and emits nothing.** The addendum says the same in
its §6, and it should be read as a hard gate rather than a suggestion.

---

## 4. Bench tests — what to run, and three fixes to the protocol

`CastR_RodTesting_HomeGuide.md` is sound in structure. Three things would corrupt the
numbers as written.

**4.1 The 1/3-length deflection is a vertical drop, not a distance along the blank.** §4 step
1 says 36 inches "measured along the rod from the tip back toward the butt — or equivalently,
36 inches straight down from the resting tip height." Those are not equivalent, and CCS part 1
settles it: the tip is deflected *vertically downward* a distance equal to one third of the
rod's length. A mark 36 inches back along the blank is a different criterion, gives a
different load, and makes the resulting IP incomparable to every published CCS number —
losing the only reason to use the CCS criterion at all.

While correcting that: CCS clamps at the handle on a shelf about 5 ft up, guides facing
**upwards**, and shims the front of the handle until the first foot of the rod is horizontal.
The HomeGuide's "level the whole rod" is not the same instruction and is not achievable on a
rod that sags under its own weight.

**4.2 The sensor's own mass changes the frequency it is measuring — and CCS already solved
this.** §5 mounts the WT901BLE a few inches from the tip and never mentions its mass. The
first bending mode of a 9 ft blank has an effective tip mass on the order of 15 g; the sensor
with case and strap is plausibly 20–30 g. That is not a correction, it is a doubling, and it
pulls the measured frequency down by tens of percent. CCS part 5 states the effect outright —
"the mere addition of weight to the tip decreases the measured frequency... one can produce
any value of frequency by simply controlling the applied weight."

CCS's answer is to standardise the added mass rather than avoid it: a lookup keyed on the
whole integer of the rod's ERN (ERN 1–15 → 40–550 grains). So the fix is better than "weigh
the sensor": **use the CCS standard mass for the Trace's ERN, and count the sensor and its
mount as part of that mass**, topping up with the difference. The result is then a real CCF,
comparable to published numbers, *and* a known tip boundary condition for the lumped model —
which is worth more to a beam simulation than a bare unloaded frequency would be.

Report it CCS's way: `CCF = 1200 / (seconds for 20 complete oscillations)`, in cycles per
minute. The HomeGuide's "1 / average time between peaks" in Hz is the same quantity by a
noisier route; the sensor recording makes the 20-cycle count trivial and exact.

**4.3 Record IP in grains; treat ERN as a lookup.** §4 step 4 half-admits it is unsure how
the conversion works. IP — the load in grains producing the 1/3-length deflection — is
unambiguous and is what the model needs. ERN comes off Table B in CCS part 1 (a lookup, not a
formula: 10 cents → ERN 0.61, 62 cents → ERN 7.90). Log IP, take ERN from the table, and use
ERN only for comparing against published rod data and for picking the §4.2 test mass.

Otherwise: the damping-ratio formula in §5 is correct for light damping, the clamp and wind
cautions are the ones that actually matter, and the logging template is fine. Run static and
dynamic on the Trace in one afternoon — but run §6's Test 3 **first**, per §3.2, because it
may change what the other two are for.

The CCS papers are worth reading before the bench session rather than the HomeGuide alone:
[part 1](https://www.common-cents.info/part1.pdf) for the static procedure and Table B,
[part 5](https://www.common-cents.info/part5.pdf) for the dynamic method.

---

## 5. Layer 3 — line

`CastR_LineLoading_Variables.md` §5–6 proposes a tip-end reaction term scaled by AFFTA line
class, taper and a user-declared carry length.

**Out of scope until Layer 2 is validated, and probably beyond it.** The reasoning is not that
the model is wrong — the AFFTA grain-weight standardisation genuinely does make line the most
tractable of the unmeasured variables. It is that Layer 3 adds free parameters to a model
that has no ground truth yet, and there is no bench test for it: a clamp and pennies measure
a rod, nothing in a garage measures a line's aerodynamic loading through a cast.

One thing is worth doing now, because it is free and unrecoverable later: **record the
declared line carry with the session.** A rough bucket — 20 / 30 / 40+ ft — costs one prompt
in `cast`. `PLAN.md` §6 already notes roughly 20 ft out the tip across the corpus but nothing
records it per session, and the day Layer 3 becomes buildable, every session recorded without
it is unusable for fitting. Same logic as capturing the calibration sequence before the solver
exists.

---

## 6. Corrections to the drafts

**6.1 "Relative to the handle" is superseded, not wrong.** `CastR_RodTipPath_Addendum.md` §2A
says the tip path comes out relative to the handle, sidestepping position drift. Correct, and
that is exactly the deflection term. But this repository already does better than treating the
handle as fixed — it puts the handle on a fitted lever arm about a pivot, with refusals when
that model does not hold. The two compose as §1 shows. The addendum was written without
knowing the swing-path reconstruction exists.

**6.2 "Loop shape upgraded to 🟡" is contingent on three things the drafts treat as done.**
`CastR_RodTipPath_Addendum.md` §5's confidence-table upgrade holds only with Tier-2 bench
parameters, a validated simulator, and a filmed comparison. Two are unbuilt and one is unrun.
Until then the framework's original 🔴 is the honest entry. Do not let the upgraded table
propagate into anything user-facing.

**6.3 Addendum 3 C.1's "nothing to reconstruct" undersells its own mode.** With no line, the
rod barely flexes — so the *geometric* tip path is not an approximation there, it is correct.
Fundamentals mode gets a real tip path, tracking and straight-line-path from Layer 1 alone.
That is a stronger product argument than the draft makes for itself.

**6.4 The tier framings collide with this project's discipline in one place only.** Class-based
defaults (RodTipPath §3 Tier 1) are the exception — see §3.3. The rest of the tiering is sound.

**6.5 Housekeeping.** `CastR_Addendum6_HeightArcCalibration copy.md` is still byte-identical to
its twin. `CALIBRATION.md` §5.4 already said to delete one.

---

## 7. Stages

### Layer 1

**T0 — rod geometry becomes data.** *Done.* `cast rod <name>` writes
`calibration/rod-<name>.json` with `rodLengthCm`, `sensorOffsetCm` and the derived
`tipFromSensorCm`, and repoints `current-rod.json`. Feet-and-inches or centimetres both
parse; a bare number is refused rather than guessed at. `tipFromSensorCm` stays blank unless
both measurements are given — a tip distance derived from one measurement and a guess is
worse than none, because nothing downstream could tell. The `bench` block is present and
null, waiting on §4.

Still open: **the rod is not recorded against a session.** `current-rod.json` says which rod
is in use now, which is enough for one rod and not enough for two.

**T1 — `MountCalibration.swift`, axis first.** *Done.* Rod axis from the stored down/up
vectors, refused with the measured disagreement when they are not acceptably antiparallel.
Clocking/TRIAD is stubbed out in the same file's doc comment and did not hold this up.
Tolerance is 10° of disagreement, against `cast`'s 30° gross-error gate — and there is a test
asserting that a pair `cast` would pass can still be refused here. Mirrored in
`reconstruct.js`; `--emit-axis-fixture` writes Swift's answers and
`verify-reconstruction.js` holds the mirror to them.

The tests also pin the blind spot: two holds leaning the *same* way agree perfectly and are
both wrong, so the error bar cannot see a consistent lean.

**T2 — tip path in `reconstruct.js`.** *Done.* `reconstruct(readings, spans, { rod })`,
taking either an `axisBody` or the `holds` to solve one from. No rod supplied → no tip
output, not a guessed one. Both paths go through one `toFrame`, and the verifier asserts the
sensor-to-tip distance holds to 1e-9 m over the whole path — which is what would catch the
two frames drifting apart. Adds `tip.radiusCm`, `tip.extentCm`, `tip.outOfPlaneCm`,
`tip.axisUncertaintyCm`, and per-segment `tipSweepCm` / `tipOutOfPlaneCm`. Inherits every
existing refusal, plus the `grounded` refusal from §2.5.

**T3 — tip-touch test (§2.7).** *The gate, and it needs a trip outside.* Nothing derived from
the tip path ships before it passes. Everything above is verified against a synthetic
fixture, which proves the arithmetic and proves nothing about the rod.

**T4 — draw it.** *Done.* A **Rod tip** toggle in the swing controls, enabled only when a tip
path exists. Tip view draws the tip path at its own scale with the sensor path ghosted
underneath and the rod drawn as one line from pivot through sensor to tip; the grid steps
10 cm → 1 m with the scale and says which it is. A **Rod** row takes the two JSON files
`cast` writes and remembers them in `localStorage`, showing the axis error bar in
centimetres at the tip. Refusals surface in the burst table, since the arm still draws and
the row would otherwise look healthy. The caveat sits under the views in the same voice as
the forward-anchor note.

**T5 — the metrics only the tip can give.** Tracking is in the readout as a per-stroke figure.
Still to come: straight-line-path deviation through the acceleration phase, arc at tip vs arc
at butt, creep during the pause, and the ground-anchored arc height consuming
`hand_height_at_ready ≈ 0.634 × H` from `CALIBRATION.md` §5.2 under that section's three
unchanged conditions. None of it enters the analyze JSON or any threshold before T3 passes.

### Layer 2

**R0 — the handle sanity check (§3.2).** Twenty minutes. Run it before anything else in this
section, including before the other bench tests.

**R1 — bench the Trace (§4).** Static IP + AA, dynamic frequency at known added tip mass,
damping. Into `calibration/rod-<name>.json`. Costs an afternoon and is useful even if Layer 2
is never built — it is the first real number about the rod in this project.

**R2 — filmed ground truth.** 240 fps side view, metre stick, one rod, a handful of casts.
Layer 2 draws nothing until this exists.

**R3 — lumped-segment simulator.** 3–6 segments, RK4, driven by base motion in the rod frame.
Parameterised by (IP/ERN, AA) per §3.5. Validated against R2 before it renders anything.

**R4 — the rod-class table (§3.5).** Rows keyed on (length, line weight, AA bucket), each
carrying an IP and AA *range*. Model runs the corners; the view draws the envelope; the
verdict is refused when the envelope spans conflicting answers. Seeded from the Batson
fly-blank rows and the CCS conversion tables, checked against the Trace's own R1 numbers.
Only worth building after R3 exists to run it through — a band around an unvalidated model
is still an unvalidated model.

### Order

T0, T1, T2 and T4 are built and verified against the synthetic fixture. **What stands between
here and a real tip path is one trip outside**: `cast calibrate` alongside a session, and the
T3 tip-touch test to find out whether the thing is telling the truth. Nothing more needs
writing first.

**R0 can and should run this week regardless** — it is twenty minutes, it needs nothing
built, and it changes what Layer 2 is allowed to claim. R1 is worth doing on the same
afternoon.

R4 is last, and deliberately so. For an MVP of one caster and one rod, the class table has
nothing to do: R1 measures the Trace directly, and a measured rod needs no bucket. Class
defaults become necessary the moment a second person's rod arrives, which is a
post-MVP problem — and by then R1 will have supplied the one thing that makes the table
trustworthy, a measured rod to check a bucket against.

---

## 8. Consequences and open questions

**The existing corpus gets no tip path.** There is no `calibration/` directory — `cast
calibrate` has never run alongside a recorded session. Every *future* session gets the axis
for free, because `CALIBRATION.md` §4's cadence already requires calibrate at session start.
The first tip path costs one outing, not a rebuild.

**Open, and worth deciding before T0:**

1. Rod file now, or rod fields in the person profile? Recommended: **rod file**, since §4's
   bench parameters need one anyway.
2. Refuse the tip path on ungrounded bursts? Recommended: **yes** (§2.5).
3. Axis solve in Swift with a parity check, or JS-only against a fixture? Recommended:
   **Swift** — `CALIBRATION.md` §6 already scoped the mount solver as a `CastrCore` job.
4. Add the line-carry prompt to `cast` now (§5)? Recommended: **yes** — one prompt, and it is
   unrecoverable after the fact.
