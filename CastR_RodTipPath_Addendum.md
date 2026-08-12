# CastR Addendum: Reconstructing Rod-Tip Path from Handle Motion + Rod Flex Data

*(Follow-on to `CastR_Analysis_Framework.md` — this addendum specifically re-evaluates the
"loop shape" gap identified there.)*

## 1. Why this works in principle

A fly rod is a **tapered cantilever beam**. Its tip motion during a cast is not arbitrary — it's
the mechanical response of a known physical structure (mass distribution + stiffness
distribution along its length) to a known input (the motion you impose at the handle end).
That is a completely deterministic engineering problem: **given base motion + beam
properties, tip motion can be computed.** This is standard structural dynamics, and it's
exactly the class of model rod manufacturers already use internally (finite-element blank
design) — you'd just be driving it with real handle data instead of a static test rig.

This reframes the earlier "🔴 not assessable" on loop shape into something closer to
**"🟡 reconstructible, with calibration and known error sources"** — a real upgrade.

What you get, per cast, if this works: an estimated 3D (or 2D, casting-plane-projected) path
of the rod tip through the stroke — which is *exactly* the input needed to distinguish a
straight tip path (narrow loop) from a convex/arcing one (wide loop), and to flag the
concave dip-then-recover signature that produces a tailing loop.

## 2. The model itself: three viable approaches, in order of practicality

### A. Lumped-segment model (recommended starting point)
Break the rod into N segments (3-6 is typically enough) connected by torsional
spring-dampers, each segment carrying a point mass. This is the standard trick used in
fishing-rod game/CGI physics and in reduced-order flexible-body simulation generally —
it avoids solving a continuous PDE and is cheap enough to run on a phone in real time.

- **Inputs per timestep:** angular position/velocity/acceleration at the base (from the IMU),
  read at the sensor's sample rate.
- **Per-segment parameters (this is the "rod profile" you hard-save):** local stiffness
  (spring constant), local mass, segment length.
- **Simulation:** forward-integrate the chain (standard ODE solve, e.g. RK4) driven by the
  base motion — each segment's angle lags/leads the one below it based on its stiffness
  and the momentary forces, exactly like a whip.
- **Output:** position of the last segment's endpoint over time = estimated tip path,
  expressed *relative to the handle*, which sidesteps IMU position-drift entirely (you only
  ever need relative angles over a ~0.3-1s stroke window, not absolute world position).

### B. Modal superposition (more "correct," more setup work)
Represent the rod's bending shape as a sum of its first 2-3 natural bending mode shapes
(each mode is a fixed spatial curve; the rod's real shape at any instant is a weighted blend
of them). Driving the base excites each mode by a known amount, computable from the
mode's known frequency and damping. This is more physically rigorous than segments-in-a-
chain, and it's how structural engineers actually analyze cantilever dynamics — but it
requires you to first compute or measure the rod's actual mode shapes/frequencies, which
is more calibration work than option A for probably little practical gain at this stage.

### C. Full Euler-Bernoulli beam PDE (not recommended for v1)
The "exact" continuum version. Solvable via finite-difference or finite-element discretization,
but it's meaningfully more compute and calibration-data-hungry for accuracy gains that
probably don't matter at the resolution you need (loop-width classification, not precision
rod engineering). Worth knowing it exists as the "ground truth" model to validate A/B
against, not something to ship.

**Recommendation: build A. Validate a handful of casts against B or a video-tracked tip
(lab-only) to confirm it's not systematically biased, then ship A.**

## 3. What "hard-saving a rod" actually requires

This is the real bottleneck — the model is cheap to run; getting good per-rod parameters is
the work. Three tiers, in increasing order of accuracy and cost:

### Tier 1 — Class-based defaults (cheapest, ships fastest)
Bucket rods by publicly known attributes: length, line weight, and manufacturer-stated
"action" (fast/medium/slow — most manufacturers already publish this, and hobbyist
communities maintain **Common Cents System (CCS)** deflection data for many popular
rods, which gives you a real measured deflection curve without your own physical testing).
Assign a generic stiffness/mass profile per (length, weight, action) bucket. Inaccurate for
any specific rod, but gets you *a* number instead of nothing, and lets the feature ship before
you've built your own rod library.

### Tier 2 — Your own physical calibration per specific rod model (the "hard-save" the user proposed)
One-time, in-house, per rod model you want to support:
1. Fix the rod at the handle (clamp), hang a known weight at the tip, measure static
   deflection at several points along the blank — this is the CCS approach, doable with a
   tape measure and a fishing scale, no special equipment.
2. This gives you the static stiffness distribution (EI(x) profile) directly.
3. For mass distribution, weigh the blank in a few segments, or use published blank weight
   + a reasonable taper assumption.
4. Optionally validate dynamically: clamp the rod, deflect the tip, release, and film the
   free-oscillation decay (natural frequency + damping) — this is a *video-assisted, lab-only*
   calibration step (never ships in the live product) that lets you sanity-check the
   lumped-model parameters against real rod physics, the same "video used only for
   offline benchmarking" pattern from the earlier framework doc.
5. Store the resulting parameter set in a rod library, keyed to make/model/length/line-weight.

### Tier 3 — Per-user self-calibration (scales without your labor, lower precision)
Guide the user through a simple one-time "twang test" with their own rod: clamp or brace
the butt, pull the tip back a set distance, release, and record the handle-end IMU signal of
the resulting oscillation as the rod settles. Even without seeing the tip directly, the *handle*
oscillation signature (frequency, decay rate) as reaction to a known tip release carries
information about the rod's stiffness/damping that can be fit to the lumped model. Less
precise than Tier 2, but lets you support "any rod" without physically testing every model
yourselves — good long-term scaling answer once Tier 2 has validated the fitting approach
works at all.

**Practical rollout: Tier 1 now (unblocks shipping), Tier 2 for your own rod + a handful of
popular ones (validates the physics), Tier 3 later as a scaling mechanism once you trust
the model.**

## 4. What this does and doesn't fix

**Fixed / meaningfully improved:**
- Straight vs. convex tip path (narrow vs. wide loop) — now inferable, not guessed.
- The concave dip-then-recover signature of a tailing loop (classically caused by an abrupt
  mid-stroke power application) is a known driven-beam response — a punchy, non-smooth
  base acceleration input produces a very characteristic tip lag/rebound in this kind of
  model, which is detectable.
- Casting arc size was already 🟢 from the base IMU signal (it's roughly the angular sweep
  at the handle); this model refines it by adding the rod's own contribution to total tip
  excursion, since the tip travels a larger arc than the handle alone due to flex.

**Still not fixed — be honest about these:**
- **The line's mass/aerodynamic loading on the rod is not in this model.** A real cast is a
  *coupled* rod+line system — the line's weight and drag genuinely affects how the rod
  loads and unloads dynamically, not just the rod's own physics in isolation. A model driven
  purely by handle motion, with no line-loading term, will systematically understate real
  tip deflection under heavier lines/rigs (sink tips, indicators, heavy flies — exactly the
  wide-loop scenarios called out in the loop-size mechanics you quoted). Mitigation: add a
  simple user-entered "rig weight class" (light dry fly / standard nymph rig / heavy
  streamer-sink-tip) as an effective added tip-mass term — crude, but better than ignoring
  it entirely, and cheap to add.
- **This is reconstruction, not measurement.** Every estimate here inherits error from (a)
  handle-motion sensing noise, (b) how good your per-rod calibration is, and (c) the
  lumped model's approximation of a continuous beam. Frame this internally and to users
  as "estimated tip path" — don't present it with the same confidence as the directly
  measured handle-level metrics (stop crispness, tempo, etc.) from the core framework.
- **Higher-frequency phenomena may be smoothed out** by a low-segment-count lumped
  model — fine for loop-width classification, possibly too coarse for very fine-grained
  "how tight exactly was this loop in degrees" claims.

## 5. Net effect on the earlier confidence table

Update from `CastR_Analysis_Framework.md` Section 4:

| Signal | Old confidence | New confidence (with calibrated rod model) |
|---|---|---|
| Loop tightness / straight vs. convex tip path | 🔴 Not assessable | 🟡 Reconstructible, calibration-dependent |
| Tailing loop detection (concave tip path) | 🔴 Not assessable | 🟡 Reconstructible via characteristic lag/rebound signature |
| Casting arc | 🟢 (handle-only) | 🟢, refined with rod's own flex contribution |

This is a genuine, defensible upgrade to CastR's differentiation — "we estimate your actual
rod-tip path from physics, not just handle timing" is a real technical moat relative to eFly's
brute-force multi-sensor approach, if the calibration work gets done credibly.

## 6. Suggested next step

Before building the rod library at scale: build the Tier-A lumped-segment simulator and
validate it against **one** rod you can physically test (Tier 2 calibration) and film for
ground truth (lab-only video). If the reconstructed tip path tracks the filmed tip path
reasonably well on that one rod, the approach is validated and the remaining work is
scaling the rod library (Tier 1 defaults + gradual Tier 2 additions), not re-deriving the
physics.
