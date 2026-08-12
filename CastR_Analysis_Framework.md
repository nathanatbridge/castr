# CastR: Analysis Framework for Replacing a Casting Instructor (No-Video, Single IMU)

## 0. The core constraint, stated plainly

A human instructor watches: the rod bend, the loop shape in the air, the line unrolling, the
caster's body (shoulders/elbow/wrist), the timing of the pause, and where the fly lands. A
single rod-mounted IMU (accel + gyro + angle, no magnetometer reliability at close range,
no video) gives you **one point of measurement on a moving, flexing lever**. That point can
tell you a lot about *timing, rotation, and force application at the handle* — but it cannot see
the tip path, the line, or the loop directly. Everything below is organized around that honest
boundary: what's **fully assessable**, what's **partially assessable via proxy**, and what's
**not assessable** without added hardware.

This matters for CastR's credibility. Overclaiming ("we detect tailing loops") when you're
really inferring from handle deceleration patterns will get caught out by any FFI-certified
instructor who tries the product.

---

## 1. Categories of analysis needed (the full stack)

To act as an instructor, the system needs five analytical layers, each building on the last:

1. **Event segmentation** — find the boundaries: backcast start/stop, pause, forward cast
   start/stop, (optional) haul events. Everything else depends on getting this right first.
2. **Kinematic feature extraction** — per segment: peak angular velocity, peak acceleration,
   duration, deceleration rate, jerk (smoothness), plane/roll angle.
3. **Cast-type classification** — which of the ~15+ cast types was just thrown, from the
   shape of the waveform alone (no explicit user input required, though allowing manual
   labeling for training data is valuable).
4. **Quality scoring against a benchmark** — comparing the extracted features to a
   reference distribution for *that specific cast type* (not a generic "good cast" — a roll
   cast and a double haul have entirely different "correct" signatures).
5. **Feedback generation** — translating a deviation ("stop was mushy," "backcast/forward
   cast power ratio inverted," "pause too short — hitting yourself on the forward stroke")
   into instructor-style language, plus session-over-session trend tracking.

Layers 1–2 are pure signal processing. Layer 3 is a light classifier. Layer 4 is where the
real R&D and data-collection burden lives — this is the "benchmark" problem you're asking
about. Layer 5 is a mapping/UX problem once 4 exists.

---

## 2. What a single rod-mounted IMU can and cannot see

### Fully assessable (direct signal)
| Signal | How it's derived |
|---|---|
| Stroke duration (backcast, forward cast) | Time between gyro-magnitude threshold crossings |
| Pause duration | Low-rotation window between backcast stop and forward cast start |
| Peak angular velocity per stroke | Max of gyro magnitude within a segment |
| Peak linear acceleration per stroke | Max of accel magnitude within a segment |
| Stop "crispness" | Peak jerk (d(accel)/dt) at end of stroke — sharp spike = crisp stop, gradual decay = mushy stop |
| Backcast:forward-cast power ratio | Ratio of peak angular velocities between the two strokes |
| Casting plane / tilt (roll axis) | Orientation angle relative to vertical — flags sidearm vs. overhead, or unintentional plane drift |
| Tempo/rhythm consistency | Variance in stroke+pause duration across repeated casts |
| Directional symmetry | Whether backcast and forward cast travel through a consistent, mirrored arc |

### Partially assessable (proxy, lower confidence)
| Signal | Why it's a proxy, not a direct read |
|---|---|
| Rod loading/flex | No strain gauge — inferred only from acceleration profile shape, confounded by rod action (fast vs. slow rods produce different signatures for identical technique) |
| Drift during the pause (line straightening) | Can infer "did the rod stay still," not "did the line actually straighten behind you" |
| Loop tightness | **Cannot see the loop.** Can weakly correlate tip-path smoothness (via rod-butt angular acceleration profile) to loop quality, but this is a rod-butt proxy for a rod-tip phenomenon — flex means they're not the same motion. Treat any "loop score" as thin evidence, not a real loop measurement. |
| Line speed / shoot distance | No line sensor, no video — can only infer relative effort, not actual output |

### Not assessable without additional hardware
- **Tailing loops, wide loops, actual loop shape** — this is fundamentally a tip-and-line
  phenomenon; a handle-mounted IMU is one flex-cycle removed from it.
- **Cast accuracy / where the fly lands** — needs external tracking (video, GPS, or a
  target-relative system).
- **Haul timing precision (single/double haul)** — needs a second sensor on the line hand,
  or at minimum a body-worn sensor; the rod IMU alone can see *that* the caster hauled
  (a secondary accel blip) far less reliably than *when relative to the stroke* it happened.
- **Wind reading / environmental adaptation** — no environmental sensor.
- **Body mechanics (shoulder/elbow/wrist sequencing)** — this is exactly what eFly's 5-sensor
  rig is for. Single rod-sensor CastR structurally cannot compete with eFly on this axis —
  don't try to; compete on price/simplicity instead, which is already your positioning.

**Bottom line:** CastR can be an excellent *timing, rhythm, and power-application coach*. It
cannot be a *loop-shape or accuracy coach* on current hardware. Feedback language should
lean into the former and be honest (or silent) about the latter.

---

## 3. How to actually build the benchmarks

This is the hard part, and there's no shortcut around collecting labeled data — but there
are cheaper and more expensive ways to do it.

### Option A (gold standard, higher cost): Expert-labeled dataset
1. Recruit FFI-certified casting instructors (or at minimum, several verifiably strong casters).
2. Have them throw each cast type repeatedly (10-20 reps each) while wearing the sensor,
   filmed simultaneously (video is used *only* in this offline lab/calibration phase — it never
   ships in the product).
3. Have the instructor rate each individual rep 1-10 on a rubric ("crispness of stop,"
   "backcast/forward-cast balance," "tempo") — ideally 2-3 independent raters for inter-rater
   reliability.
4. Extract the Layer-2 features (Section 1) for every rep, and regress/classify features →
   instructor score. Simple models (logistic regression, gradient-boosted trees) work fine
   at this data scale — you don't need deep learning for tabular features from ~300-500
   labeled reps.
5. This gives you a genuine "what does a 9/10 forward cast's angular velocity curve look
   like" reference distribution *per cast type*, not a guess.

This is the only path to a benchmark you can defend if a skeptical instructor asks "how do
you know that's good?" It requires a dedicated data-collection session(s) — budget this
explicitly as its own project phase, separate from app/algorithm dev.

### Option B (cheaper, faster, weaker): Template-matching against a single expert
1. Have one strong caster throw a clean reference rep of each cast type.
2. Store that rep's angular-velocity waveform as a template.
3. Score new casts by similarity to the template using **Dynamic Time Warping (DTW)** —
   handles the fact that no two casts have identical timing, but shape/rhythm should match.
4. Cheap to build, ships fast, but the "benchmark" is really "how much like this one person"
   rather than a validated quality signal. Fine for MVP / beta, should be clearly framed
   internally as a placeholder, not a finished benchmark.

### Option C (no expert data at all): Self-referential progress tracking
1. Skip absolute "good/bad" scoring entirely.
2. Track the user's own metrics (tempo consistency, stop crispness, power ratio) session
   over session and report *change*, not *grade* ("your stop crispness is up 15% from last
   week," "your tempo variance is tightening").
3. This is honest, ships immediately, requires zero labeled data, and is genuinely useful —
   but it is not "replacing an instructor," it's "a mirror." Good as a Stage 2 MVP feature
   while Option A data collection happens in parallel.

### Cross-cutting requirements for any benchmark approach
- **Normalize per rod.** A fast-action 4wt and a slow-action 8wt produce very different
  acceleration signatures for identical technique. Either require rod metadata at setup, or
  normalize features by the rod's own idle/calibration swing.
- **Normalize per user's mount calibration.** Sensor mounting angle varies session to
  session; require a brief calibration step (hold rod level, tap to confirm) before each
  session, or auto-detect gravity-vector orientation at rest.
- **Handle left/right-handed casters** — mirror the sign convention on yaw/roll.
- **Filter non-casting motion** — walking, wading, handling the rod between casts —
  before segmentation runs, or false segments will pollute the benchmark data itself.

---

## 4. Cast-type catalog: what "effective" looks like per cast (IMU-only)

Confidence key: 🟢 Full · 🟡 Partial/proxy · 🔴 Not assessable without added hardware

| Cast Type | Purpose | IMU Signature of an Effective Cast | Confidence |
|---|---|---|---|
| **Pick-up-and-lay-down (basic overhead)** | Foundational cast | Smooth acceleration to a sharp deceleration spike (crisp stop) on both backcast and forward cast; forward-cast peak angular velocity ~1.1-1.5x backcast; pause duration proportional to line length (longer line = longer pause) | 🟢 |
| **False cast** | Extend line/dry fly without landing | Same stop/tempo signature as overhead cast, repeated 2+ times with consistent tempo across reps (rhythm consistency is the key differentiator vs. a single delivery cast) | 🟢 (timing/rhythm) · 🔴 (whether line actually stayed airborne) |
| **Roll cast** | No backcast room | Single forward stroke only (no backcast rotation detected beforehand); D-loop formation shows as a slower, larger-radius rotation before the accelerating forward stroke; crisp forward stop | 🟢 (stroke count/timing) · 🟡 (D-loop quality is a rod-butt proxy) |
| **Single haul** | Add line speed on one stroke | Secondary short-duration accel blip on the line-hand side timed near the end of the loaded stroke — **only detectable if the sensor placement/second sensor captures line-hand motion**; on a rod-only sensor this shows up faintly as a slight acceleration bump, low confidence | 🟡 |
| **Double haul** | Add line speed on both strokes | Two such blips, one per stroke | 🟡 (needs 2nd sensor for real confidence) |
| **Steeple cast** | Overhead obstruction | Backcast rotation shows a steep upward angle change (pitch axis) rather than the standard horizontal-ish arc; otherwise same stop/tempo criteria as overhead cast | 🟢 (angle) |
| **Reach cast** | Mend line at delivery | Forward stroke identical to standard cast, but followed by a distinct lateral rotation (yaw/roll) *during* the unrolling phase, after the forward stop | 🟡 (post-stop motion is inherently lower-signal) |
| **Curve cast (positive/negative)** | Bend the leader | Forward stroke ends with a deliberate off-axis roll/yaw twist at the moment of the stop (rather than a straight-line stop) | 🟡 |
| **Puddle/parachute cast** | Slack presentation | Forward stroke decelerates *before* full extension (early, soft stop rather than a crisp one) — note this inverts the "crisp stop = good" rule, so cast-type classification must run before quality scoring | 🟡 |
| **Tuck cast** | Fly enters water fast, vertical | Sharp downward pitch rotation concentrated at the very end of the forward stroke, higher peak deceleration than standard cast | 🟢 |
| **Bow-and-arrow cast** | Tight quarters, short range | No real backcast rotation at all; a single sharp release-style acceleration spike from a held/loaded position | 🟢 |
| **Sidearm/side cast** | Wind/obstruction | Same as overhead cast but casting plane (roll angle) rotated ~90° from vertical | 🟢 |
| **Wiggle/mend cast (aerial mend)** | Add slack mid-air | Series of small lateral (yaw) oscillations introduced after the forward stop, before the line settles | 🟡 |
| **Change-of-direction cast** | Redirect without a full false cast | Large yaw rotation between backcast and forward cast (rather than the backcast/forward cast staying in the same plane) | 🟢 |
| **Switch cast** | Single-hand/light two-hand, no backcast | Waterborne anchor (rod-tip dips, then a sustained load builds) before a single forward stroke — similar signature family to roll cast | 🟡 |
| **Spey casts (Single Spey, Double Spey, Snake Roll, Snap-T, Circle Spey)** | Two-handed, no backcast room, water-borne anchor | All built around: anchor placement (line/water contact — invisible to an IMU), a sweep (slower rotation), then an accelerating forward stroke with a crisp stop. The sweep and stroke are 🟢, but **anchor placement/quality — arguably the single most instructor-critiqued element of Spey casting — is 🔴, unassessable without seeing the water/line.** Do not claim Spey coaching without flagging this gap explicitly to users. | 🟡 overall, with a 🔴 core |

**Practical recommendation:** Build and validate the benchmark for the **overhead-cast
family (pick-up-and-lay-down, false cast, basic delivery) first.** It's the highest-confidence,
highest-frequency, easiest-to-benchmark group, and it's what beginners/intermediates
(your stated target segment) actually need most. Treat haul detection, curve/reach casts,
and especially Spey as a v2+ roadmap item requiring either a second sensor or an explicit
"partial confidence" framing in the app.

---

## 5. What this means for hardware/roadmap decisions

- **Single sensor (current WT901BLE prototype) is sufficient** for a genuinely useful v1:
  timing, tempo, stop quality, and power-ratio coaching on standard overhead-family casts.
  This alone would already beat "no feedback at all" and is a defensible MVP claim.
- **A second sensor (line hand or upper arm)** would unlock real double-haul timing and
  meaningfully improve Spey-cast feedback — worth flagging as a "Pro" tier hardware
  upgrade rather than baseline, consistent with your existing hardware-bundle pricing model.
- **Video remains the only way to ever assess loop shape or accuracy directly.** If a
  premium/pro tier ever wants to compete with eFly on that axis, it needs either video
  input (phone camera, Training Mode is already phone-in-view) or a rod-tip sensor in
  addition to the handle sensor — both are real options given Training Mode already has
  the phone out. Worth a note in `CASTR_HANDOFF.md` as a considered-and-deferred idea
  rather than something to build now.

---

## 6. Suggested next step for the algorithm workstream

Given `cast_analysis.py` already does segmentation and per-segment metrics: the immediate
gap is Layer 4 (benchmarking). Recommend Option B (single-expert DTW template) as a
fast v1 to get *something* shipping in Training Mode, while scoping a proper Option A
data-collection session (a few hours with 3-5 solid casters, filmed, self-rated or
rated by a local instructor) as a discrete, budgeted task — this is exactly the kind of
primary-research gap the market-validation deck already calls out, just applied to the
algorithm side instead of the pricing side.
