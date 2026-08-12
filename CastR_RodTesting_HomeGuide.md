# CastR: At-Home Rod Testing Guide — Static Deflection (ERN/AA) & Dynamic (CCF/TNF)

*Companion to `CastR_Addendum3_DataAndNoLinePractice.md`. This is the practical "how to
actually do it in your garage" version of that protocol, written for the Redington Trace
9-foot but generalizable to any rod you add to the library later.*

## Before you start: one important correction from the last doc

The earlier addendum suggested mounting the WT901BLE at the **handle** for the dynamic
test, reasoning it'd be "closer to how the product will actually sense things." That's true
for the *product*, but wrong for *this specific test* — if you clamp the rod rigidly at the
handle (which the test requires), the handle doesn't move at all. All the oscillation
happens at the tip. So for the dynamic test, the sensor needs to temporarily live near the
**tip** to actually see anything. This guide has you run a second, optional variant with the
sensor at its normal handle position to separately check how much of that tip motion is
even detectable from where the sensor will really live in the product — a useful, honest
data point in its own right.

---

## 1. What you'll come away with

- **ERN** (Effective Rod Number — real-world line weight the rod actually wants)
- **AA** (Action Angle — where along the rod it flexes: tip/mid/full)
- **TNF** (True Natural Frequency — how fast the rod oscillates, unloaded)
- Optionally, **CCF** (Common Cents Frequency — the standardized version with a test mass)
- A rough read on whether your product's actual sensor placement (near the handle) can
  detect rod dynamics at all, or whether it's too attenuated at that position

---

## 2. Materials checklist

**For securing the rod:**
- A sturdy table, workbench, or similar fixed surface near an open area (garage, basement,
  hallway, or outdoors on a calm/no-wind day)
- 2 C-clamps or a bench vise
- Scrap foam, rubber, or a folded towel/rag to pad the clamp jaws — **never clamp bare
  graphite directly**, it will crack or crush the blank
- ~10 feet of clear horizontal space in front of the clamp point (a 9ft rod clamped near the
  very butt needs nearly its full length free to deflect)

**For the static (ERN/AA) test:**
- A small lightweight bag or pouch (a small ziploc or a paper cup with a string handle works)
- Either: ~40-50 pennies dated after 1982 (each weighs a standardized ~2.5g / 38.6 grains),
  **or** — easier and more precise if you have one — a small digital kitchen/postal scale
  that reads grams, so you can just weigh the pouch directly instead of counting coins
- A tape measure or yardstick
- Painter's tape or a marker to flag your reference points
- A phone with a level/angle-finder app (most phones have one built into a compass or
  measurement app), or a protractor, to read the Action Angle

**For the dynamic (TNF/CCF) test:**
- Your WT901BLE sensor
- Removable mounting: a hook-and-loop (Velcro) strap, or a small piece of reusable mounting
  putty/gel tape — avoid anything adhesive enough to damage the blank's finish when removed
- Your phone/laptop running the CastR data-collection app (or the stock WitMotion app) to
  log the sensor stream during the test
- A stopwatch (backup only — the sensor recording is your real data source)
- Optional: a small known weight (a few pennies taped together, or a fishing weight) if you
  want to also run the full CCF version with added tip mass

**General:**
- The rod itself (Redington Trace, 9ft — confirm exact model/weight rating before you start,
  since it goes in the data label)
- A notebook or spreadsheet open to log results as you go — don't rely on memory
  afterward

---

## 3. Securing the rod

1. Pick your clamp point: **right at the base of the handle/reel seat**, as close to the true
   butt end as you can get while still having solid material to clamp (avoid clamping on the
   cork grip itself if the blank is exposed just below it — clamp the exposed blank/reel
   seat area if possible for a more rigid, repeatable hold).
2. Pad both clamp jaws with foam or a folded rag.
3. Clamp so the rod extends straight out horizontally, tip pointing into open space, with
   nothing beneath it for the first few feet (you'll be letting the tip drop several inches to
   a couple feet during testing).
4. **Confirm it's actually horizontal** — use your phone's level app resting on the rod near
   the clamp. A rod that starts even slightly tilted will throw off both tests.
5. Mark the resting tip height on a wall, doorframe, or a vertical stick placed just past the
   tip — you'll reference this as your "zero" position for both tests.
6. Give it a light tap and make sure the clamp is fully rigid — no wobble, no slipping. If it
   moves at all, tighten or re-pad before continuing.

---

## 4. Test 1: Static Deflection (ERN + AA)

1. **Mark the 1/3-length point.** For a 9ft (108") rod, that's exactly **36 inches** measured
   along the rod from the tip back toward the butt — or equivalently, 36 inches straight
   down from the resting tip height at your zero mark. Put a piece of tape on the wall/stick
   at that point.
2. **Rig the pouch.** Tie or hook your lightweight bag onto the tip-top guide (the very last
   guide at the tip). Note the bag's own weight before adding anything to it — you'll
   subtract this later, or better, tare your scale with the empty bag on it first.
3. **Load it gradually.**
   - *Coin method:* Add pennies one at a time, checking tip position after each, until the
     tip has dropped exactly to your 36" mark.
   - *Scale method (recommended if available):* Add small increments of anything (rice,
     washers, more pennies) until the tip hits the mark, then weigh the total pouch contents
     on your digital scale in grams.
4. **Record the weight.** Convert to grains if your scale reads grams (1 gram ≈ 15.43
   grains). This is your rod's **Intrinsic Power (IP)**.
   - Sanity check: needing roughly 25-30 pennies (~65-75g / ~1000-1150 grains... note:
     actual CCS reference tables convert this differently — use the count/weight primarily
     as your own consistent baseline, and cross-reference against a published CCS
     conversion table if you want the formal ERN number) typically lands in 4-5wt territory,
     which is a reasonable expectation for a rod labeled around that weight.
5. **Measure the Action Angle.** With the tip still loaded and held at the 36" mark, use your
   phone's angle-finder app: hold the phone against the rod at the clamp point to establish
   the horizontal reference, then sight or measure the angle between that horizontal line
   and a straight line from the clamp point to the deflected tip position. This is your **AA**
   — a higher angle means the bend is concentrated more toward the tip; a lower angle
   means it's bending more through the full length of the rod.
6. **Repeat 2-3 times.** Unload, let the rod fully rest back to zero between trials, and
   re-run. Your numbers should be closely consistent — if they're not, check your clamp for
   slipping.
7. **Log:** rod name, date, IP (grains), ERN (if you cross-reference a conversion table), AA
   (degrees), and how many trials you averaged.

---

## 5. Test 2: Dynamic Test — True Natural Frequency (TNF)

This is the one that feeds your lumped-segment model's stiffness/damping terms — prioritize
getting this one clean.

1. **Remove any load from the static test** — tip should hang free, no pouch attached.
2. **Temporarily mount the WT901BLE near the tip.** Use your Velcro strap or mounting
   putty to attach it a few inches back from the tip-top (attaching exactly at the fragile
   tip-top itself risks damage — a few inches back is fine and still captures the oscillation
   clearly). This is a **temporary calibration position**, different from where the sensor
   lives during normal casting — that's expected and fine.
3. **Start recording** on your phone/laptop app, and let it run continuously through the
   whole test — better to capture a few extra seconds of stillness before and after than to
   miss the moment of release.
4. **Deflect the tip 2-4 inches** downward from its resting position — a small, consistent
   deflection, not a big pull. Hold briefly, then **release cleanly** (a crisp release, not a
   push or throw) so the rod oscillates freely on its own.
5. **Let it fully settle** before stopping the recording — you want the whole decay, not just
   the first few cycles.
6. **Repeat 4-5 times** with as close to identical deflection distance and release technique
   as you can manage — consistency here matters more than any single trial being "perfect."
7. **Stop recording, save the file**, and label it clearly (rod name, "TNF test," trial number).

### Pulling the numbers out of the recording
- Open the gyro or accel channel that shows the clearest oscillation (whichever axis lines up
  with the rod's main bending plane — check your sensor's mounting orientation notes).
- Find the timestamps of consecutive peaks (or zero-crossings) after release.
- **Frequency (Hz) = 1 / (average time between consecutive peaks)**, or for a CCS-style
  number, time how long it takes to complete 20 full oscillations and divide 20 by that
  duration.
- **Damping (optional but useful):** compare the amplitude of the 1st peak to the amplitude
  of a later peak (say, the 5th): damping ratio ≈ (1 / (2π × number of cycles between them))
  × ln(amplitude of peak 1 / amplitude of later peak). This tells you how quickly the rod's
  oscillation dies out — a real input for your simulation's damping term, not something you'd
  otherwise have a number for.

---

## 6. Test 3 (optional but recommended): Sensor-at-handle sanity check

This isn't part of the standard CCS/TNF protocol — it's a check specifically for your
product, to see whether the position the sensor will actually occupy during real casting can
detect rod dynamics at all.

1. Move the WT901BLE to its **normal product-mounting position** — just above the grip,
   where it'll sit during actual casting sessions.
2. Rather than rigidly clamping the butt this time, either hold the rod naturally as if
   casting, or rest the butt loosely against a table edge as a pivot (not clamped).
3. Deflect the tip the same 2-4 inches and release, same as Test 2.
4. Record and compare: does the handle-mounted sensor show a clear, usable oscillation
   signal, or is it heavily damped/attenuated compared to the tip-mounted recording from
   Test 2?

**Why this matters:** if the handle position barely registers the rod's own dynamics, that's
an important, honest finding — it would mean your live product data (always sensed at the
handle) needs to lean more heavily on the pre-calibrated rod profile (from Tests 1-2) to
infer tip behavior, rather than expecting to see much direct dynamic signal from the handle
sensor during a real cast. Better to learn this now, from a controlled bench test, than to
discover it later from confusing field data.

---

## 7. Logging template

Keep this consistent across every rod you ever test, so your library stays comparable:

```
Rod: Redington Trace, 9'0", [line weight label]
Date tested:
Test conditions: [indoor/outdoor, temp, wind]

STATIC TEST
Trial 1: IP = ___ grains, AA = ___ degrees
Trial 2: IP = ___ grains, AA = ___ degrees
Trial 3: IP = ___ grains, AA = ___ degrees
Average IP: ___   Average AA: ___
ERN (if cross-referenced): ___

DYNAMIC TEST (tip-mounted)
Trial 1: TNF = ___ Hz
Trial 2: TNF = ___ Hz
Trial 3: TNF = ___ Hz
Trial 4: TNF = ___ Hz
Average TNF: ___ Hz
Damping ratio (if calculated): ___

HANDLE SANITY CHECK
Signal clearly detectable? [Y/N]
Notes on attenuation/quality:

Raw sensor files saved as: [filenames]
```

---

## 8. A few things that will quietly ruin your data if you skip them

- **Wind.** Even a light draft will disturb the free-oscillation test and add noise you'll
  mistake for damping. Test indoors or on a dead-calm day.
- **Clamp slip.** If your ERN numbers drift noticeably between trials, it's almost always a
  loose clamp, not the rod. Re-check rigidity before trusting the data.
- **Inconsistent release technique.** A "thrown" or pushed release on the dynamic test adds
  extra energy that isn't part of the rod's natural response — practice a clean, simple
  release a couple of times before your recorded trials count.
- **Sensor orientation drift between sessions.** Note (even just with a photo) exactly how
  and where the sensor is mounted each time, so results from different testing days are
  actually comparable to each other.
