# CastR session protocol

Everything runs from `~/Desktop/Castr`. One command per step; the script asks for the
rest. This card is what to type when it does.

```sh
cd ~/Desktop/Castr
cast protocol      # prints this card
```

## Order of operations

| # | when | command |
|---|---|---|
| 1 | first time this person is recorded, ever | `cast profile <person>` |
| 2 | start of every session, and after any remount | `cast calibrate` |
| 3 | each recording | `cast <person> <test>` |

Step 3 runs the sensor health check itself and prompts for step 2 if today's poses are
missing, so on a normal day you only ever type step 3.

---

## 1. `cast profile <person>` — once per person

Three typed answers, then one optional motion capture.

| prompt | what to put in |
|---|---|
| `Height (e.g. 5ft10 or 178cm), Enter to skip:` | `5ft10` or `178cm`. Either format. |
| `Casting experience (beginner / occasional / experienced):` | one of those three words |
| `Rod (make, length, weight, action if known):` | `Orvis Clearwater 9ft 5wt` — as much as you know |

**Answer the experience question honestly.** A beginner's inconsistent stroke is valuable
data, but only if it can be told apart from a sensor fault. Its absence is currently a
named gap in the corpus — Sam's arcs run 24% wider than everyone else's and there is no
way to tell practice from inexperience.

Then the **shoulder sweep** (optional — press `s` at the prompt to skip). It runs as three
timed steps, same as `cast calibrate`: the screen tells them when to move and when to stop.

> "Let your casting arm hang straight down at your side, with the rod lined up along your
> arm. Hold it there. When I say raise, bring the rod straight out in front of you to
> shoulder height — one smooth movement, pivoting at the shoulder only — and hold it there.
> I'll tell you when to move and when to stop."

| | | |
|---|---|---|
| 1 | arm down at your side | hold 4 s |
| 2 | **raise** out in front to shoulder height | 4 s — this is the measurement |
| 3 | arm out at shoulder height | hold 4 s |

Step 2 is the part being measured; the two holds bracket it and give the gravity reference
at each end. Keep the elbow out of it and don't let the trunk lean in — either one is a
second pivot and corrupts the number.

Afterwards you get `[Enter] keep it  [r] do it again  [s] skip`. Redo it freely: stillness
is all the software can check, and whether they bent the elbow or stopped short of shoulder
height is visible only to you.

Writes `calibration/profile-<person>.json`.

---

## 2. `cast calibrate` — start of every session

One continuous 30 s capture, all held in the hand. It **checks the connection first** and
only starts timing once data is flowing, then counts you through each step on screen — you
never have to time anything or press Enter mid-sequence.

Read out to whoever is holding the rod:

> "Hold the rod down at your side, arm hanging straight down, rod lined up along your arm.
> Stay still until I tell you to swing."

Press Enter once they're in position and still. From there the screen drives it:

| | | |
|---|---|---|
| 1 | rod down at your side, arm hanging | hold 5 s |
| 2 | **swing up** — one smooth movement | the swing is measured too |
| 3 | arm straight up, rod tip at the sky | hold 5 s |
| 4 | bring the rod down to point forward | |
| 5 | arm out, rod straight ahead and level | hold 5 s |

Then it prints the geometry it recovered:

- **down → up ~180°** — a consistency check. Off means the rod wasn't lined up along the
  arm, or the arm didn't finish upright.
- **up → forward ~90°** — the one that matters. Step 5 is the only position where gravity
  runs across the rod instead of along it, which makes it the only one that can see how the
  housing is rotated on the blank. A sloppy forward hold costs the whole calibration.

Keep the holds genuinely still — steady enough that the rod isn't drifting. A momentary
twitch is fine; a slow sag is not.

The solver that consumes all this isn't written yet. Capture it anyway: thirty seconds now,
and it's the only thing that lets a session be re-referenced later.

## 3. `cast <person> <test>` — the recording

```sh
cast dad 20ft
```

The name is derived for you. Never type a filename, and never worry about overwriting —
a second run of the same command becomes `dad-20ft-2.csv` and says so.

### Picking `<test>`

| test | what it is | tags |
|---|---|---|
| `updown` | reference motion, no cast. **Do this first for a new person.** | off |
| `noline` | short sequences, no line | on |
| `20ft` | 20 ft of line, real deliveries | on |
| `fish` | natural fishing, progressive line | on |
| `falsecast` | counted forward false casts | off |
| `tagged` | two-person, a second person tags every stroke | on |

New person, in order: `updown` → `noline` → `20ft` → `fish`.

### Prompts you'll hit

| prompt | what to put in |
|---|---|
| `Press Enter when it is still and untouched…` | put the sensor **flat on a hard surface, hands off**, then Enter. 5 s. |
| `[c] calibrate now [s] skip and record anyway [q] quit` | `c` (or just Enter). Only use `s` if you calibrated and it's after midnight. |
| `Press Enter to connect` | Enter, then **wait for `▶ GO — START CASTING`** before you move. It has to scan and connect first, and anything you do before GO isn't in the file. **Ctrl-C when the session is done.** |
| `>` (notes) | rod, wind, anything odd — one line. Enter to skip. Goes to `sessions.log`. |

### While recording

Tag keys, pressed **as each stroke finishes**:

```
1 pickup     2 false back     3 false forward     4 delivery
```

- Late presses are fine and corrected for. The tagger watches the caster, not the screen.
- **Don't press anything until it says it's recording.**
- Watch that `rejected` stays at `0`. A rising count is the only signal that framing broke.
- Delivery tags currently mis-match during analysis with line on — **press `4` anyway.**
  The tap and its timestamp are saved correctly; only the matching is wrong, and it gets
  re-run when the fix lands. Nothing is lost.

On Ctrl-C it analyses the session, takes the note, and copies both files to
`~/Documents/castr-sessions`.

---

## The one thing no command can check

**Mount the sensor in the same spot and the same rotational orientation every single
time** — immediately above the cork handle, same face up. The casting axis is a body-frame
axis; rotate the housing on the rod and it moves to a different axis, and cross-session
comparison silently breaks. Nothing in the software can see that you got this wrong yet.

---

## When something fails

| it says | do this |
|---|---|
| health check `FAIL`, gravity not 1.000 g | run the acceleration calibration in the WitMotion app, leave the sensor still, then `cast check` |
| health check `FAIL`, "the sensor was moving" | it's not still — flat surface, hands off, rerun |
| pose `FAIL — the rod moved during the window` | better footing or support, retry. A shaky pose is worse than none. |
| poses `only N° apart` | redo the vertical pose — it wasn't upright enough |
| `Nothing recorded` / `the sensor never connected` | sensor on and charged? BLE range is ~10 m, and the Mac has to be outside with you |
| `Only N samples` | capture was cut short; that isn't a session, redo it |

Every failure states a reason. If it says it failed, trust that over forcing a result
through.

---

## Where things land

```
Sessions/<person>-<test>.csv         the recording   (gitignored, backed up)
Sessions/<person>-<test>.events.csv  stroke tags     (only if any were pressed)
Sessions/sessions.log                your typed notes
calibration/<stamp>.json             mount poses
calibration/profile-<p>.json         per-person profile
```

Backup copy goes to `~/Documents/castr-sessions/` automatically.

## Deeper detail

- `CAPTURE.md` — the recording protocol and why each step exists
- `CALIBRATION.md` — the calibration protocol, and what is measured vs. assumed
- `PLAN.md` — what the data has proven and what it broke
