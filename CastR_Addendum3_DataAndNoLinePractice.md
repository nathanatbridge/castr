# CastR Addendum 3: AFFTA Data Compilation, CCS/TNF Testing Protocol, and No-Line Practice Mode

## Part A — AFFTA Standard Fly Line Weights (compiled reference table)

Official AFFTA specification, weight of the first 30 feet of line excluding the level tip.
Use this as your Tier-1 line-weight default table (per `CastR_LineLoading_Variables.md`,
Section 4).

### Single-handed lines

| Line Weight | Grains (Low–Target–High) | Grams (Low–Target–High) |
|---|---|---|
| 1  | 54–60–66   | 3.5–3.9–4.3   |
| 2  | 74–80–86   | 4.8–5.2–5.6   |
| 3  | 94–100–106 | 6.1–6.5–6.9   |
| 4  | 114–120–126| 7.4–7.8–8.2   |
| 5  | 134–140–146| 8.7–9.1–9.5   |
| 6  | 152–160–168| 9.9–10.4–10.9 |
| 7  | 177–185–193| 11.5–12.0–12.5|
| 8  | 202–210–218| 13.1–13.6–14.1|
| 9  | 230–240–250| 14.9–15.55–16.2|
| 10 | 270–280–290| 17.5–18.15–18.8|
| 11 | 318–330–342| 20.6–21.4–22.2|
| 12 | 368–380–392| 23.8–24.6–25.4|
| 13 | 435–450–465| 28.2–29.2–30.2|
| 14 | 485–500–515| 31.1–32.4–33.7|
| 15 | 535–550–565| 34.3–35.6–36.9|

### Two-handed (Spey) lines
Weighted at a distance-specific "weight point" rather than a flat 30ft, since Spey heads are
much longer. Reference only — out of scope for your current v1, included for completeness
since you may want it later.

| Line Wt | Shooting Head (grains/g) @40ft | Short Belly (grains/g) @55ft | Medium Belly (grains/g) @65ft | Long Belly (grains/g) @80ft |
|---|---|---|---|---|
| 6  | 250/16.2 | 420/27.3 | 460/29.9 | 600/39.0 |
| 7  | 300/19.5 | 470/30.5 | 510/33.1 | 650/42.2 |
| 8  | 360/23.4 | 530/34.4 | 570/37.0 | 710/46.1 |
| 9  | 430/27.9 | 600/39.0 | 640/41.6 | 780/50.6 |
| 10 | 510/33.1 | 680/44.2 | 720/46.8 | 860/55.8 |
| 11 | 600/39.0 | 770/50.0 | 810/52.6 | 950/61.7 |
| 12 | 700/45.5 | 870/56.5 | 910/59.1 | 1050/68.2|

### Important caveat for your database, confirmed by research
Real commercial lines routinely drift from their nominal label — <cite index="15-1">a line sold as "5wt" from one manufacturer can measure in the 160–165 grain range, which is actually a true 6wt by the AFFTA numbers, while another manufacturer's 5wt lands right at the 140-grain target</cite>. So: use this table as your Tier-1 default/fallback, but treat any specific product's published or measured grain weight as an override once you have it. Don't assume the number on the box is the physical truth.

---

## Part B — CCS / TNF Rod Deflection Testing: Protocol for the Redington Trace

**Search finding, stated plainly:** there is no published CCS or TNF data for the Redington
Trace in the community databases I could find. You'd be originating this data, not looking
it up — which is consistent with the "hard-save it yourself" plan from the last addendum.
Worth deciding now whether to also submit your results to the public CCS database once
you have them — it's community-maintained and your data point would be useful to others
building on this rod, and might surface others' independent measurements later as a
cross-check.

### B.1 — Static test: ERN (power) and AA (Action Angle)
This gives you the rod's overall stiffness number and *where* it bends (tip-flex vs. full-flex),
which is your starting stiffness-profile input for the beam model.

1. **Secure the rod horizontally** by the handle/butt, clamped so it can't rotate, tip
   pointing out over open space.
2. **Mark the deflection point.** For a 9-foot rod, 1/3 of the length is exactly 36 inches —
   convenient, since <cite index="22-1">for a 9-foot (108-inch) rod, the 1/3 deflection point works out to 36 inches, marked as a spot 36 inches below the rod's resting tip height</cite>. This is your target for the Trace.
3. **Load the tip.** <cite index="22-1">Hang a small, lightweight bag from the tip-top guide and add post-1982 pennies one at a time, since post-1982 US pennies have a standardized, consistent weight of 2.5 grams each (about 38.6 grains)</cite>. <cite index="43-1">A very light reel plus a plastic bag can also be used, filled gradually until balanced under the extremity of the grip where the angler would normally hold the rod.</cite>
4. **Stop at the mark.** Add pennies until the tip deflects down to your 36-inch mark.
5. **Record the count.** <cite index="24-1">The mass required to deflect the blank this predefined distance is the rod's Intrinsic Power (IP), which converts via a standard reference table to the Effective Rod Number (ERN) — effectively an objective measure of "what line weight this rod actually wants."</cite> <cite index="22-1">As a rough anchor, needing around 25–30 pennies typically lands you in 4wt–5wt territory</cite> — useful as a sanity check on your count.
6. **Record the Action Angle.** <cite index="43-1">With the rod loaded this way, the angle formed by the tip relative to the horizontal axis is the Action Angle — it indicates whether the rod flexes mostly at the tip, through the middle, or full-length.</cite> This is the number that tells you *where along the beam* the stiffness is concentrated — directly useful for shaping your EI(x) stiffness-distribution curve in the lumped-segment model, rather than treating the rod as uniformly stiff.

### B.2 — Dynamic test: CCF / True Natural Frequency
This is the one that matters most for your driven-beam model — it directly measures the
rod's natural oscillation frequency, which is exactly the parameter the lumped-segment
model needs to reproduce real dynamic (not just static) rod behavior. Two versions, easiest
first:

**Simple version (True Natural Frequency, no added mass):**
<cite index="44-1">Deflect the tip roughly 2–4 inches and release it to start it oscillating; a smartphone or tablet can record the vibration by lightly touching the tip to the screen, or you could substitute your own WT901BLE sensor mounted at the handle for this, which is arguably a more direct proxy for what your product will actually sense in the field.</cite> <cite index="44-1">This unweighted oscillation rate is the rod's True Natural Frequency (TNF), a dynamic measure of how the rod actually behaves — distinct from static power/action numbers.</cite> <cite index="44-1">Use light, consistent deflections and repeat the test multiple times to check for consistency.</cite>

**Full CCS version (CCF, with a standard test mass):**
<cite index="43-1">With the rod fixed horizontally by the grip, attach a weight (sized per the rod's own ERN from part B.1) near the tip-top, load the rod again, then release the tip abruptly so it oscillates vertically.</cite> <cite index="42-1">Time how long it takes for the tip to complete 20 full oscillations — the faster those 20 cycles complete, the higher the frequency and the more reactive the blank is.</cite> This gives you a standardized, comparable-across-rods frequency number (CCF) rather than just your own rod's raw TNF.

**Why this matters for your model specifically:** natural frequency + decay rate (how
quickly the oscillation dies out) together define the damping and stiffness terms your
lumped-segment simulation needs to reproduce believable dynamic tip behavior — this is
precisely the "Tier 2 dynamic validation" step flagged as a to-do in
`CastR_RodTipPath_Addendum.md`, and you now have a concrete, established protocol to run
it rather than inventing one from scratch.

### B.3 — Recommended sequence for the Trace
1. Static ERN + AA test (confirms actual line-weight match — useful data regardless of the
   physics model, and a good sanity check against the "9 foot 5wt" label).
2. TNF test using your own WT901BLE sensor at the handle instead of a phone screen touch
   — this doubles as your first real validation that the sensor can pick up the rod's own
   dynamic signature at all, before you ever put a line on it.
3. Repeat both a few times for consistency, per the standard protocol's own recommendation.
4. If time allows, repeat the static deflection test at 2–3 points along the rod (not just the
   standard 1/3 point) to sketch a rough bending curve rather than a single ERN/AA pair —
   this is the same idea as the CCS "Bending Index Graph" concept and gets you much closer
   to a real EI(x) profile than a single-point measurement.

---

## Part C — A no-line "fundamentals" practice mode

### C.1 — Why this is a genuinely good idea, not just a nice-to-have
A line-less rod has almost no tip loading, so the physics-based tip-path/loop-shape
reconstruction from `CastR_RodTipPath_Addendum.md` has little to reconstruct — there's no
line mass pulling on the tip, so the rod barely flexes and the "tip path vs. handle path"
distinction that drives loop-shape assessment mostly disappears. **But that's exactly why
this mode is useful, not a reason to skip it:** real casting instructors already teach
mechanics without a line for a reason — it isolates arm/wrist timing and stop crispness
from the added complexity of line handling. You'd be building a software version of a
drill instructors already use, not inventing a workaround.

### C.2 — What's still assessable without any line at all
All of the **Layer 1–2 handle-level metrics** from the original framework survive intact,
because they're about the caster's arm/wrist motion, not the rod's flex response:
- Stroke duration and tempo/rhythm
- Backcast/forward-cast timing symmetry and power ratio
- Stop crispness (peak jerk at the end of the stroke)
- Casting plane consistency (roll axis)

These are arguably the *most foundational* things a beginner needs to get right before line
handling even enters the picture — which lines this mode up well with your stated target
segment (beginners/intermediates) and your existing Training Mode framing.

### C.3 — What's not meaningfully assessable in this mode
- Loop shape / tip-path reconstruction — no load, no meaningful flex, nothing to
  reconstruct.
- Casting-arc-matched-to-load coaching ("your arc is too small for this much line") —
  there's no line to match the arc to.
- Anything from the line-loading variable map in `CastR_LineLoading_Variables.md` — that
  entire model is inert in this mode by design.

### C.4 — Product/design implication: this needs its own benchmark, not a scaled-down version of the loaded one
A common mistake would be to treat "no-line practice" as just a low-intensity version of
loaded-cast benchmarks. It isn't — an unloaded rod's natural stop/tempo signature is
physically different from a loaded one (this is exactly what the CCS/TNF test in Part B
measures: the rod's *unloaded* natural frequency is a distinct, different number from how
it behaves under a real casting load). So:
- Build a separate reference distribution for unloaded-stroke metrics, ideally from the
  same expert-labeled data collection session proposed in `CastR_Analysis_Framework.md`
  Section 3 — just have your experts throw a few unloaded reps alongside their loaded ones.
- Frame this in-app explicitly as a **"Fundamentals" mode**, distinct from Training Mode,
  rather than a stripped-down Training Mode — this also sets the right expectation with
  users about what it can and can't tell them.
- This is a strong onboarding/no-equipment-needed feature: someone can start using CastR
  the moment they have the sensor and a rod, indoors, before ever stringing a line — which
  lowers the barrier to first use meaningfully compared to needing a lawn or a river.

### C.5 — One nuance worth flagging
There's a middle case between "full line out" and "completely bare rod": a rod with just a
leader and practice fly/yarn attached but no fly line — which is close to, but not identical
to, true zero load. Worth deciding whether "no line" in your product means literally bare
rod (Fundamentals mode) or leader-only (which is closer to your originally-scoped practice
setup and may want to just be the low end of the existing Line Loading model rather than a
separate mode). Recommend treating truly bare-rod as its own Fundamentals mode, and
leader-only-practice as the minimal case of the standard model — keeps the two use cases
conceptually distinct rather than blurring into a single ambiguous "low load" bucket.

## Part D — Suggested next step
Run the Part B protocol on the Trace this week if possible — it's a low-cost, high-value
test (an afternoon, some pennies, your own sensor) that gives you real numbers to start
building the lumped-segment model against, rather than continuing to plan in the abstract.
