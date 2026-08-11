# CastR Calibration Protocol

*(Companion to `calibrate.js`. Run this once per session, or any time the sensor
is remounted or feels like it may have shifted on the rod.)*

## What this fixes, and what it doesn't

The mounting housing almost certainly sits a few degrees off the rod's true
centerline. Nothing downstream of the raw sensor data knows that on its own —
gravity-based grounding (already in `reconstruct.js`) tells you which way is
"up," but it can't tell you whether the housing itself is twisted on the
blank. This protocol solves for that fixed offset using two still poses with
a known, unambiguous relationship to the rod's own axes.

**What it does not fix:** rotation about the rod's own long axis (i.e. the
housing clocked around the blank). Gravity can't see that in either pose
below — a limitation of physics, not of the math. If the housing can spin
independently of the clamp, that's a mechanical fit problem to solve
separately, not something recalibrating will paper over.

---

## Pose 1 — Flat

**Lay the rod flat on the ground, reel down, dead still, for 3-5 seconds.**

- This defines "up" as the rod's own vertical axis when at rest.
- Reel-down matters — it fixes which way is "up" consistently between
  sessions. Pick one convention and stick with it every time you calibrate.
- Hold it as still as you can. A rod that's still gently settling or resting
  on uneven ground will show up as pose jitter and get rejected — better to
  find a flat surface and wait a beat than to record a shaky pose and hope.

## Pose 2 — Vertical

**Stand the rod on its butt, tip pointed straight up at the sky, dead still,
for 3-5 seconds.**

- This defines "up" as running along the rod's own length, butt to tip.
- Braced against a wall or held with two hands is fine — the requirement is
  stillness, not an unsupported balancing act.
- This pose should read roughly 90° away from Pose 1 in the sensor's own
  data. If it doesn't, the calibration will fail and tell you why rather
  than silently accepting it — see "What can go wrong" below.

Poses 1 and 2 alone are enough to solve the full mounting offset — they're
deliberately chosen to be orthogonal to each other, which is what makes the
math well-conditioned with only two poses.

---

## User profile reference measurements (separate from mounting calibration)

Poses 1 and 2 above solve a fixed *mechanical* property — how the housing
sits on the rod — and should be redone whenever the sensor moves. The two
measurements below are a different category entirely: **per-user physical
reference points**, captured once (not per session), used for normalizing
metrics across casters rather than for correcting sensor orientation. Keep
them conceptually separate from the mount calibration above — they don't
feed `calibrateMount()`.

### Arm-length reference: shoulder sweep

**Start with your casting arm hanging straight down at your side, rod
aligned with your arm, sensor mounted as normal. Raise the rod straight out
in front of you to shoulder height — a clean ~90° sweep from the shoulder —
then hold still.**

- This is a controlled version of the same fit the core algorithm already
  does: `reconstruct.py`/`reconstruct.js` estimates a pivot-to-sensor
  distance from rotational dynamics during a swing, then uses that radius to
  turn integrated gyro angle into a reconstructed arc — angle × radius =
  swept position, anchored by gravity at the still windows so it doesn't
  drift the way double-integrated position would. The radius isn't a
  side detail; it's the direct multiplier that turns "how the sensor
  rotated" into "where the rod tip was" for the ideal-vs-actual overlay.
  A more accurate radius means a more accurate arc, not just a more
  confident-looking number.
- Doing that same fit through a known, single-joint (shoulder-only) rotation
  gives you a way to check whether the fit recovers a sane, consistent
  number before trusting it on messier real-cast data, where the pivot
  blends shoulder/elbow/wrist and shifts by cast type.
- Be precise about what this number actually represents: it's
  **shoulder-to-sensor distance**, not "casting arm length" in a general
  sense — real casting doesn't pivot purely at the shoulder. Label it as
  such in stored data rather than implying it's a direct stand-in for the
  in-cast pivot arm.
- Keep the motion consistent between captures: same relaxed starting
  position, same "straight out at shoulder height" endpoint, and try not to
  let trunk lean sneak in as a second, uncontrolled pivot.
- One-time capture per user (redo only if useful to re-check, not part of
  the regular per-session routine).

### Body height

**Record the caster's height as a simple profile value — no sensor capture
needed.**

- Alongside the arm-length sweep, this gives a starting-elevation and scale
  reference for the caster independent of any single session's fitted
  numbers.
- Purpose is normalization, not correction: a taller caster with a longer
  reach will naturally produce a larger absolute swing radius for
  *identical* technique. Without a body-scale reference, that shows up as a
  bigger number in the data with no way to tell whether it reflects body
  size or actual technique — height and arm length let you normalize before
  comparing casters, or before comparing one caster against a benchmark
  distribution, rather than accidentally scoring physical size as if it were
  skill.

Both values belong in a **user profile**, stored once and reused across
sessions — not in the per-session calibration file alongside the mounting
offset.

## Doing the capture

For each mounting-offset pose (Flat, Vertical):

1. Get into position and hold still *before* starting the capture window —
   don't start recording while still settling into the pose.
2. Capture for 3-5 seconds. Longer isn't better once you're genuinely still;
   it just raises the odds of a mid-window twitch getting caught in the
   window.
3. If using `castr-collect --calibrate` (once the CLI-side capture flag
   exists — see the spec discussed separately), the tool will gate the
   capture live and tell you immediately if a pose wasn't held still enough,
   rather than letting you find out after the fact.

## What can go wrong (and what it means)

| Failure | What it means |
|---|---|
| "pose not held still enough" | Rod moved more than ~3° during the window — find better footing/support and retry. |
| "flat and vertical poses were only N° apart — expected close to 90°" | One of the two poses wasn't actually distinct from the other — likely both were closer to flat, or the vertical pose wasn't upright enough. Redo Pose 2. |
| "not enough still samples" | Capture window was too short or got cut off — retry with the full 3-5 seconds. |

Every failure reports a reason rather than silently producing a number — if
calibration says it failed, trust that over forcing a result through.

## Why two calibration poses instead of one

A single still pose only fixes 2 of the 3 rotational degrees of freedom (it
tells you which way is up, but not whether the housing is twisted around
that axis). Two poses at a known angle to each other — here, 90° apart by
construction — fix all three. This is the standard two-vector attitude
determination approach (TRIAD), the same category of method used elsewhere
in the pipeline for gravity-based grounding, just applied to a fixed
mechanical offset instead of a per-burst orientation.

## Suggested cadence

- Run the full 2-pose mounting calibration (Flat + Vertical) once at the
  start of each session, and again any time the housing is removed and
  remounted.
- Capture the arm-length sweep and body height once per user, when they're
  first set up — not something to redo every session. Revisit only if
  there's a specific reason to think the number is off (e.g. it's a
  different person using the sensor).
