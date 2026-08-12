# CastR Addendum 2: Rod + Line Loading Variables & Line Database Standardization

*(Follow-on to `CastR_RodTipPath_Addendum.md`. Scope for this pass: standard floating
line + a practice fly/yarn (hookless dry fly or wool, the instructor-standard reference load).
Indicators, split shot, sinking lines, and heavy flies are logged as future variables in
Section 4 but explicitly excluded from the v1 model.)*

## 1. Why line matters as much as rod

The rod doesn't load on its own — it loads because it's flinging a mass (the line) that
resists acceleration. Rod manufacturers rate a rod for a specific line weight for exactly this
reason: **the "action" you feel is really the rod+line system's combined response, not the
rod alone.** So the lumped-segment tip-path model from the last addendum is incomplete
without a term for the reaction force the line exerts on the tip — confirmed by the AFFTA
system itself, which exists specifically because <cite index="6-1">line weight is what loads and bends the rod during casting, allowing the caster to propel a nearly weightless fly</cite>.

## 2. The line is standardized — that's the good news

Unlike rods (no universal stiffness spec), fly lines already have an industry-wide numeric
standard you can build directly on top of:

- <cite index="3-1">The AFFTA standard measures the weight of the first 30 feet of fly line, excluding the level tip that attaches to the leader, in grains</cite>.
- <cite index="2-1">A 5-weight line, for example, should weigh between 134 and 146 grains for that first 30 feet under the standard</cite>.
- <cite index="3-1">As a rule of thumb, line weight effectively shifts by about one class for every 5 feet of line added to or subtracted from the 30-foot standard</cite> — this is directly useful: it means effective loading as a function of line-length-out is already a documented, roughly-linear-ish relationship you can build a first-pass formula from, rather than having to derive it from scratch.
- <cite index="4-1">Weight-forward (WF) lines concentrate most of their mass in the front portion of the line, which helps with distance and turning over larger flies, while double-taper (DT) lines have a symmetrical taper suited to more delicate short-range presentation</cite> — meaning the *shape* of the mass distribution, not just the total mass, changes rod loading differently between line types.
- Real-world lines drift from the nominal spec — <cite index="7-1">a line labeled 5wt from one manufacturer can measure closer to a true 6wt from another</cite> — so the label alone isn't precise enough for a physics model; you'd want measured or manufacturer-published grain charts per specific product where possible, falling back to nominal AFFTA class otherwise.

This means the line side of your database is largely **compiling existing public data**, not
originating it from scratch the way rod flex profiles are.

## 3. Full variable map (rod + line, v1 scope)

| Variable | Why it matters for the tip-path model | Standardization source | v1 status |
|---|---|---|---|
| **Rod length** | Sets the beam's total span; changes lever arm and natural frequency | Manufacturer spec (always published) | ✅ Include |
| **Rod action/stiffness profile (EI(x))** | Determines how the rod bends under a given load — the core of the tip-path model | Own physical calibration (CCS-style deflection test) or published CCS community data where available | ✅ Include — this is the "hard-save per rod" work from the last addendum |
| **Rod mass distribution** | Needed for the lumped-segment inertia terms | Blank weight (published) + taper assumption, or your own segment weighing | ✅ Include |
| **Line weight class (AFFTA number)** | Sets nominal grain-weight-per-30ft, the primary loading term | AFFTA standard chart, public | ✅ Include |
| **Actual measured grain weight of the specific line product** | Real lines drift from nominal class; matters if you want precision beyond "close enough" | Manufacturer spec sheets where published, or your own scale measurement | ✅ Include where available, fall back to nominal AFFTA class otherwise |
| **Line taper type (WF/DT/level)** | Changes *where* the line's mass sits, not just how much — affects the effective loading curve as line is worked out | Manufacturer taper diagrams (some publish full taper profiles), otherwise a generic WF/DT shape assumption | ✅ Include as a shape-class variable even before exact per-product taper data exists |
| **Line length outside the rod tip during the stroke ("line carry")** | The single biggest dynamic variable — a false cast with 15 ft out loads completely differently than one with 50 ft out, and this changes *during* a session as line is worked out | No IMU measurement possible directly — must be user-input at session start ("practicing with ~30 ft of line"), or approximated from stroke duration/tempo correlation as a secondary signal | ✅ Include, as a user-set or estimated parameter |
| **Leader + tippet length/material** | Minor mass/drag contribution vs. the fly line itself, but affects turnover and total effective tip-load slightly | Standard practice leader specs (length, taper, material) are well documented in casting-instruction contexts | 🟡 Include as a small fixed offset, not a primary variable |
| **Practice fly / yarn "load"** | The instructor-standard reference load — deliberately near-massless and drag-standardized specifically to isolate the rod+line mechanics from fly-specific effects, which is exactly why it's the right v1 baseline | Treat as a fixed, near-zero constant in the model (a hookless dry fly or a small tuft of wool has negligible mass/drag compared to the line itself) | ✅ Include as the fixed reference case |
| Line density/sink rate (floating/intermediate/sink-tip) | Changes both mass and drag substantially, and would require modeling water-surface interaction on the backcast pickup | Manufacturer density specs exist | ⏸ Deferred — v1 assumes floating line only |
| Indicators / split shot / added weight | Adds a discrete point mass at a specific point on the leader | Would need its own mass + attachment-point variable | ⏸ Deferred — explicitly out of scope for v1 per your framing |
| Heavy/bulky flies (streamers, articulated, etc.) | Adds mass + significant aerodynamic drag at the terminal end | Would need drag-coefficient modeling, likely fly-specific | ⏸ Deferred |
| Wind | External force on the line's exposed length | Would need environmental sensor or user input | ⏸ Deferred |

## 4. How to standardize a line database, concretely

Recommended structure, keyed the same way a rod entry would be:

**Line table schema (conceptual):**
- `manufacturer`, `product_name`, `nominal_affta_class`
- `measured_grain_weight_30ft` (from spec sheet if published, else nominal AFFTA midpoint)
- `taper_type` (WF / DT / level / shooting head)
- `taper_profile` — ideally a distance-vs-grain-weight-per-foot curve if the manufacturer
  publishes one (some do, for their higher-end lines); otherwise a generic shape template
  per taper_type, scaled to the line's total 30ft weight
- `total_head_length` (relevant for WF lines — where the "belly" ends and thin running line
  begins matters for how loading changes as more line is worked out past that point)

**Build order, cheapest to most precise:**
1. **Nominal-class-only v1**: every line is just its AFFTA number, generic WF or DT shape
   assumption, no per-product distinction. Ships immediately, reuses your Tier-1 rod
   approach from the last addendum — "close enough to be useful," not precise.
2. **Add measured/published grain weights** per specific product as you gather spec
   sheets — a compiled table, not a physical testing project, since manufacturers publish
   this. Meaningfully tightens accuracy for the specific lines your users actually own.
3. **Add real taper profiles** for popular lines where manufacturers publish them (a
   distance-weighted curve rather than a single 30ft number) — this is the piece that
   actually differentiates WF vs. DT loading behavior in the model rather than just total
   mass, and is worth doing once 1-2 are validated to matter.

This mirrors the rod-tier structure exactly on purpose: **generic class defaults now, real
per-product data layered in over time, physical/precise data reserved for validation and
your own gear.** Same rollout logic, same reason — don't block shipping on data collection
that can be improved incrementally later.

## 5. How "line carry" (line-out-of-rod-tip) folds into the physics model

This is the one variable in the whole system that's both the most dynamically important
and the least directly measurable. Two ways to handle it for v1, not mutually exclusive:

- **User-declared session parameter.** Simplest: ask "about how much line are you
  practicing with?" at session start (a rough bucket — 20ft / 30ft / 40ft+ is plenty of
  resolution), and use the AFFTA rule of thumb (~one line-class equivalent per 5 ft
  deviation from the 30ft standard) as the scaling formula for effective loaded mass.
- **Secondary inferred signal.** Stroke duration and required stroke arc both increase with
  more line out (this is literally what casting instructors teach — more line means a wider
  arc and slower tempo). So once you have real data, stroke duration could become a
  weak corroborating signal for line-carry, letting you sanity-check or auto-suggest the
  user-declared value rather than trusting it blindly. Not reliable enough to be the sole
  source of truth, but useful as a cross-check.

## 6. Net effect on the model

With this in place, the tip-path reconstruction becomes: **handle motion (IMU) → driven
through a lumped-segment beam whose stiffness/mass comes from the rod's calibrated
profile → with an added tip-end reaction term scaled by (line AFFTA class, taper shape,
declared line-carry length) → practice-fly/yarn treated as a fixed near-zero terminal mass.**
That's a complete, scoped-down version of the coupled rod+line system — accurate enough
to be useful for loop-shape classification on the standard instructor practice setup, and
structured so indicators/heavy rigs/sinking lines can be added later as additional terms
without re-architecting anything.

## 7. Suggested next step

Compile the AFFTA nominal grain-weight table (1wt-14wt) plus a generic WF and DT taper
shape template as your Tier-1 line defaults — this is a pure data-compilation task, doable
in an afternoon from public manufacturer spec sheets, and unblocks running the full
loading model end-to-end on synthetic or real IMU data before any per-rod physical
calibration work begins.
