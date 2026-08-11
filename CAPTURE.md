# Capture protocol

How to record a session so it's usable later. Follow this every time — the corpus is
only comparable if the procedure is.

The Mac has to come outside with you: BLE range is ~10 m and the iOS app still isn't
buildable. Check the sensor is charged before starting a multi-person session.

---

## The whole thing, one command

```sh
cast dad 20ft
```

That builds if needed, picks the filename, runs the health check and refuses to go on
if it fails, prints the protocol for that test, waits until the sensor is actually
streaming and then says **GO**, records, analyses the result, takes a one-line note,
and copies both files to the backup. Ctrl-C ends the recording.

```sh
cast <person> <test>     updown | noline | 20ft | fish | falsecast | tagged
cast calibrate           mount sequence — start of session, and after any remount
cast profile <person>    per-person reference measurements — once, not per session
cast check               health check on its own
cast list                what has been recorded so far
cast protocol            the field card
```

**Before the first recording of a session, run `cast calibrate`** — one continuous 30 s
capture of three held positions with the swings between them. `cast` prompts for it if
today's sequence is missing. `CALIBRATION.md` is the protocol and explains why it is worth
capturing before the solver that consumes it exists.

**Order for a new person:** `updown` first — it is the reference motion that fixes which
axis is the casting axis — then `noline`, `20ft`, `fish`.

```sh
cast nate updown
cast nate noline
cast nate 20ft
cast nate fish
```

Two things it will not do for you. It cannot see the sensor, so **mounting it in the same
spot and the same rotational orientation every time is still on you**. And it will not
overwrite a recording: a second `cast dad 20ft` becomes `dad-20ft-2.csv` and says so.

Recordings land in `Sessions/`. Notes go to `Sessions/sessions.log`, which is the one place
casting experience and rod details get recorded — `PLAN.md` §6 lists their absence as a
live gap in the corpus.

The rest of this document is why each step exists. The script is it made executable; read
on when something looks wrong, not before every session.

---

## Naming

`Sessions/<person>-<test>.csv`, lowercase, no spaces. The sidecar follows automatically.

```
dad-noline.csv       dad-20ft.csv       dad-fish.csv       dad-tagged.csv
bro-noline.csv       bro-20ft.csv       bro-fish.csv
nate-noline.csv      ...
```

Anything unnamed lands as `CastR_<timestamp>.csv`, which tells you nothing six months
later.

---

## Every session, before recording

**1. Mount the sensor** on the rod immediately above the cork handle — the same spot
and **the same rotational orientation** every time. Same face up, same alignment.

This matters more than it sounds. The casting axis is a body-frame axis (X in every
session so far). Rotate the sensor on the rod and it moves to a different axis, and
cross-session comparison breaks until the frame-normalization work lands.

**2. Health check**, sensor still on a flat surface, hands off:

```sh
./.build/debug/castr-collect --check
```

Must read ~1.000 g. Re-run this whenever the sensor is remounted or a rod changes —
it takes 15 seconds and it's the only thing standing between you and a session that
looks fine and isn't.

**3. Record:**

```sh
./.build/debug/castr-collect -o Sessions/dad-20ft.csv --despike --rate 200
```

Ctrl-C to stop. Watch `rejected` stays at 0.

---

## Test 0 — `<person>-updown.csv` (reference motion, no line)

Not a cast. A deliberate up-and-down rod motion in a single vertical plane, where
every stroke's direction is known **by construction**. This is the reference
recording: it fixes which body axis is the casting axis, which sign means up, and
whether the detector counts what actually happened.

Do it once per person, first. It takes about a minute.

Stand square, rod in the vertical plane, and don't let it drift sideways — the value
of this recording is that it's single-axis.

| | |
|---|---|
| 1 | Rod horizontal, pointing forward. Hold **completely still** 5 s. |
| 2 | **Block A — 10 slow cycles.** Rod up, pause ~1 s, rod down, pause ~1 s. Always start **up**. Count them out loud. |
| 3 | Hold **completely still** 5 s |
| 4 | **Block B — 10 fast cycles.** Same motion, brisk, **no pause at either end** — reverse straight into the next stroke. |
| 5 | Hold **completely still** 5 s |

Run it with tagging off — the four casting labels don't apply here:

```sh
./.build/debug/castr-collect -o Sessions/nate-updown.csv --despike --rate 200 --no-tags
```

**Expected: 40 strokes**, 20 per block, signs strictly alternating, starting with
whatever sign "up" turns out to be. Anything else is a finding:

- Fewer than 20 in Block B means reversals are still being merged — that's the exact
  defect `splitAtReversals` was written to fix, and this is its cleanest test case.
- A different count between blocks means segmentation is tempo-sensitive.
- Any axis other than the session's dominant one means the rod drifted out of plane.

The still period in step 1 also gives a clean gravity reference from a known pose,
which is what Stage 2's frame normalization will need.

---

## The three tests, per person

Same rod for everyone if possible — that isolates casting mechanics from rod
behaviour. If someone uses their own rod, note it (see *Write down* below); it's a
second variable, not a problem.

### Test 1 — `<person>-noline.csv` (no line)

Several short sequences with clear stops between them.

| | |
|---|---|
| 1 | Hold **completely still** 5 s |
| 2 | Lift the rod back (pickup) |
| 3 | 3–5 false casts |
| 4 | Final forward stroke — press **`4`** |
| 5 | Hold **completely still** 5 s |
| 6 | Repeat from 2, three or four times |
| 7 | Then **one sequence that just stops** — false cast, then quit, no final stroke. Don't tag it. |

The still periods matter as much as the casting: they mark burst boundaries and give
the rod-attitude baseline. A session with no still moments can't be measured against
anything.

### Test 2 — `<person>-20ft.csv` (20 ft of line)

Same structure as Test 1, with real deliveries — let the line shoot and land. Include
one deliberate non-delivery stop again.

After each delivery, **let the line land and hold still 5 s**. That's the
follow-through window.

### Test 3 — `<person>-fish.csv` (natural fishing, progressive line)

Fish the way you actually would. Start ~15 ft, work line out as you go. Press **`4`**
on each delivery, nothing else.

Afterwards note the rough start and end line length. Since line only goes out, burst
order becomes a proxy for line length.

---

## Bonus: the two-person tagged session

**Do this at least once while you have people.** It's the validation set for the whole
classifier and it can't be done alone — solo tagging of all four labels has already
been shown to fail (`benchtest1` came back as nine deliveries).

`<person>-tagged.csv`. One person casts, **a second person tags every stroke**:

```
1 pickup    2 false back    3 false forward    4 delivery
```

Press as each stroke finishes. Late is fine and expected — reaction lag is corrected
for. The tagger watches the caster, not the screen.

One good 2–3 minute session is worth more than several sloppy ones. This is the only
data that can answer "is the classifier right" with a number instead of an opinion.

---

## Write down, per person

None of this is in the CSV and none of it can be recovered later:

- **Who**, and **casting experience** — beginner / occasional / experienced. A
  beginner's inconsistent stroke is *valuable* test data, but it has to be
  distinguishable from a sensor problem.
- **Rod** — make, length, weight, action if known. Note if it's not the shared rod.
- **Anything odd** — wind, a fluffed sequence, a pause to untangle, casting left-handed.

A plain text file next to the recordings is fine.

---

## Known issue while recording

**Delivery tags currently mis-match during analysis** (`PLAN.md` §4a). With line on,
you're reacting to the line landing rather than the rod stopping, so taps arrive
2–10 s late and fall outside the matcher's window — `benchtest3` matched 0 of 5.

**Press `4` anyway.** The raw tap and its timestamp are written to the sidecar
correctly; only the stroke-matching is wrong, and it gets re-run once the fix lands.
Nothing is lost.

Also: don't press keys before the sensor connects. Taps during "Scanning…" are written
with timestamps that precede the first sample and are currently kept silently
(`PLAN.md` §4b).

---

## After

```sh
swift run castr-analyze Sessions/dad-20ft.csv
```

Then copy the new recordings to the backup — they are gitignored and the project
folder is their only home:

```sh
cp ~/Desktop/Castr/Sessions/*.csv ~/Documents/castr-sessions/
```
