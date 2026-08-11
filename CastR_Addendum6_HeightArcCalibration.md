# CastR Addendum 6: Anthropometric Height Calibration for Arc-Height Normalization

*Append this section to the calibration protocol document / `CASTR_HANDOFF.md` under the
existing "User Profile" calibration section, alongside arm-length capture (pivot-arm
hang-to-horizontal swing) and body height.*

## 1. Problem being solved

The single-integration lever-arm reconstruction (per `CastR_RodTipPath_Addendum.md`)
recovers arc *shape* reliably within a bounded stroke window, but that shape is relative —
it has no fixed reference to the ground. Without a ground-referenced anchor, the
ideal-vs-actual overlay can't distinguish "this caster's arc is too low for their own body"
from "this is just what a shorter caster's correct arc looks like." A single absolute
arc-height band applied to every user would misjudge casters at either end of the height
range.

**Key framing: this is not a new sensing problem.** It does not require measuring elevation
or position with the IMU (which is not reliably possible per the single- vs.
double-integration boundary already established). It's a one-time geometric calculation
from data the calibration protocol already collects — body height and arm length — applied
once per user profile, not re-derived every session.

## 2. What's already captured (no new data collection required)

- **Body height** — already a User Profile field.
- **Arm length** — already captured via the pivot-arm hang-to-horizontal swing fitting
  algorithm.

This addendum adds a derivation step that runs on those two existing values. No new
calibration motion, no new sensor reading, no new user-facing step beyond what's already
in the protocol.

## 3. Anthropometric reference formulas

Standard ergonomic/kinesiology ratios, expressed as a fraction of total body height (H):

| Reference point | Formula | Notes |
|---|---|---|
| Shoulder height (pivot anchor) | ≈ 0.82 × H | Standing, relaxed posture |
| Hand height, arm relaxed at side | ≈ 0.45 × H | Baseline reference only, not casting-relevant |
| Hand height, casting-ready position (elbow ~90°, forearm ~horizontal) | Shoulder height − (forearm-length contribution) | Forearm contribution derived from measured arm length, not a fixed ratio — see §4 |

These are population-level averages; treat them as **Tier-0 defaults** consistent with the
tiered-confidence approach used elsewhere in the project (rod and line data). They're a
reasonable starting point, not a precision claim — flag internally the same way Tier-0 rod
specs are flagged as lower-confidence than physically measured values.

## 4. Combining with measured arm length

Body-height ratios alone give a population-average shoulder height. Measured arm length
(already captured) refines the casting-ready hand height specifically for that user, rather
than relying purely on a height-based average:

1. Compute shoulder pivot height: `shoulder_height = 0.82 × body_height`
2. From measured arm length, derive the forearm segment (standard sub-ratio: forearm ≈
   0.44 × total arm length as a Tier-0 default, refinable later if you ever want to capture
   forearm length as its own calibration step).
3. Casting-ready hand height ≈ `shoulder_height − (forearm_length × sin(θ))`, where θ is
   the elbow angle at the caster's neutral ready position (90° default, i.e. forearm
   horizontal, giving `sin(90°) = 1` and simplifying to `shoulder_height − forearm_length`
   as the default case).
4. Rod-butt/sensor height at address = `casting-ready hand height − grip offset` (grip
   offset is a fixed, near-constant value — distance from hand center to sensor mount
   point — and can be treated as a small fixed constant per the same logic already used for
   leader/tippet length in the line-loading model).

## 5. Output: a per-user calibration constant, not a live measurement

The result of this calculation is stored once in the user profile as a fixed constant:
**ground-referenced starting height of the rod/hand at address.** It does not need
recalibration session-to-session unless the user's profile (height/arm length) changes —
this is the same "hard-save once" logic already used for rod stiffness profiles.

This constant becomes the vertical anchor for the ideal-vs-actual arc overlay: the
relative arc shape recovered from single-integration is scaled and positioned against this
ground-referenced starting point, so a 5'2" caster and a 6'4" caster are each judged
against their own correct arc envelope rather than a single absolute band.

## 6. What this does *not* solve, and doesn't need to

- This does not give real-time elevation tracking during the stroke — that remains
  unnecessary. The arc's *shape* over the stroke still comes from the existing
  single-integration reconstruction; this addendum only anchors that shape's *starting
  reference point* to the ground.
- This does not require the WT901BLE (or any sensor) to sense absolute position. All
  position-adjacent capability stays confined to the relative, bounded-window
  reconstruction already validated as sound.

## 7. Suggested next step

Add the two derived fields (`shoulder_pivot_height`, `casting_ready_hand_height`) to the
User Profile calibration output alongside the existing height/arm-length inputs, computed
automatically at profile-save time using the formulas in §3–4. No new UI capture step is
needed — this is a pure computation layered onto data collection you've already built.
