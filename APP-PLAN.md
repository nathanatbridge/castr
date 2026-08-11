# Castr as an app — master plan, iteration 1

How the project becomes something you open rather than something you run. `PLAN.md`
covers the stroke-identification algorithm and keeps its own roadmap; this document
covers the product around it. They advance in parallel and meet at Phase I.

**Decision, made 2026-08-06:** web app first to validate what a session should say,
then quickly to a native iOS app for the field. Audience is one person — you. No
accounts, no cloud, no App Store.

---

## 1. Why this order

The two halves answer different questions and only one of them is blocked.

**The web app answers "what should this thing tell me?"** That question is unsettled
and it is cheap to iterate on in a browser: no build step, no signing, no device, and
`docs/` already deploys itself to GitHub Pages on push. Getting it wrong costs an
afternoon.

**The native app answers "can I leave the laptop at home?"** That question is already
settled — the answer is yes, and it needs CoreBluetooth. Safari does not implement Web
Bluetooth and Apple has never shipped it, so a browser can never be the field recorder
on an iPhone. There is no web path to the thing the native app is for. But it is
blocked on installing Xcode, which is a multi-hour download.

So: **start the Xcode download today**, do the web work while it runs, and carry the
answers into iOS. The two phases are not sequential in wall-clock time, only in what
each one teaches the other.

---

## 2. What already exists — honest inventory

`START-HERE.md` describes `docs/` as a drag-drop analyser. It undersells it. What is
actually live at `https://nathanatbridge.github.io/castr/`:

| Already there | Where |
|---|---|
| CSV parse + full stroke analysis, parity-checked against Swift | `docs/analysis.js` |
| Summary strip, rotation-rate trace over the session | `index.html` §trace |
| Per-stroke table | §strokes |
| Swing path — side + overhead, burst chips, play/scrub/flip | `docs/reconstruct.js` |
| Consistency: rep CV, per-metric spreads | §consistency |
| Two-session A/B comparison | §compare |
| Light/dark theme | — |

That is most of a session report. What is missing is what makes it an *app* rather than
a viewer:

- **It forgets.** `var sessions = []` at `docs/index.html:366`, capped at two by
  `sessions.shift()` at :434. Refresh the page and everything is gone.
- **It can't take a tag sidecar.** `handleFiles` at :406 calls `parseCSV` on every
  dropped file, so dropping the natural pair `fish1.csv` + `fish1.events.csv` reads the
  sidecar as a recording and fails column validation. You get an error banner for doing
  the obvious thing.
- **No labels, no classifier.** Grouping by stroke type is `castr-analyze` only.
- **No history.** Comparison is A/B against whatever you happen to have dropped, not
  against the last six weeks.

On the iOS side: `ios/ContentView.swift` (233 lines) and `ios/CastRDataCollectorApp.swift`
exist and are complete enough to be a recorder — scan, connect, live readout, record,
four tag buttons with haptics, share sheet. **Not one line has ever been compiled.**
No Xcode, no iOS SDK. Parse-checked only. Expect to fix things on first build.

---

## 3. The architecture decisions

These four are the load-bearing ones. Everything in §5–§7 follows from them.

### 3a. Swift is the authority. JavaScript is a surrogate.

`tools/verify-web-parity.js` currently keeps `analysis.js` and `StrokeAnalysis.swift` in
agreement, and that has been worth having. But `PLAN.md` Stages 2–5 — session casting
frame, burst segmentation, the classifier, label validation — are all substantial new
analysis, and porting each one to JS to keep parity would roughly double the cost of the
hardest work in the project, at exactly the moment the algorithm is most in flux.

**Policy:** new analysis lands in Swift only. `analysis.js` stays at its current
feature line and stays parity-checked *on that line*. The web app is where the
presentation is designed, not where the algorithm advances.

This has a consequence that must not be papered over: a parity tool that silently
covers less than it appears to is a trap — a green check that means "the shared subset
still agrees", read as "the two implementations agree". **Make `verify-web-parity.js`
print what it does not cover**, by name, every run. Same discipline as the ten blank
CSV columns: absent and *said to be absent*, never fabricated.

The payoff is on the iOS side. The app links `CastrCore` directly, so every classifier
improvement arrives in the app for free, with no port and no drift.

### 3b. Local only. No backend, no accounts, no sync.

Audience is one person. GitHub Pages stays static; the iOS app keeps its sessions in its
own container. This is not a placeholder for a cloud phase — it is the right shape for
the stated audience, and it keeps the zero-dependency constraint intact.

### 3c. Zero third-party dependencies holds on both sides.

The web app stays vanilla JS in the style it is already written in. No framework, no
build step, no bundler — `docs/` deploys by being pushed. iOS is SwiftUI plus the two
local packages. Same rule as `CLAUDE.md` states, extended to the app.

### 3d. One name: **Castr**. One origin: **castrtech.com**.

The repo, `CLAUDE.md`, and this plan say Castr. `README.md` and `ios/` say CastR. Once
there is a home-screen icon and an app name, the inconsistency stops being cosmetic.
Rename `CastRDataCollectorApp.swift` → `CastrApp.swift` and the `README` title during
Phase X, before anything is signed.

`castrtech.com` is owned. It currently points at Squarespace — apex resolves to
`198.49.23.144`, `www` is a CNAME to `ext-sq.squarespace.com`. Nothing in this repo
references it and `docs/` has no `CNAME` file.

**Both identities have to be picked before their phase stores anything, because both
are storage boundaries and neither migrates:**

| Identity | Set in | What moving it later destroys |
|---|---|---|
| Web origin — `castrtech.com` | `docs/CNAME` + DNS | IndexedDB is scoped per origin. Session history saved at one hostname does not follow the app to another. |
| Bundle ID — `com.castrtech.castr` | Xcode target, X2 | iOS treats a changed bundle ID as a different app. It installs fresh alongside the old one; the on-device session library does not come with it. |

Neither is hard to get right and both are unpleasant to get wrong, so they are §6 and
§9 prerequisites rather than details. Owning the domain is what makes the bundle ID
easy: reverse-DNS off a domain you actually control, decided once, never revisited.

---

## 4. What iteration 1 is *not*

Stated so it stays out by decision rather than drifting in.

- Multi-caster, coaching, or anything social.
- Cloud sync, accounts, TestFlight, App Store.
- Video sync. `README.md` warns host-clock drift makes this unsafe without a check.
- Apple Watch, or using the phone's own IMU instead of the WT901.
- Real-time feedback during a cast. Analysis happens after the stroke, not during.
- Live coaching diagnosis (tailing loops, creep). Needs the bad-cast corpus in
  `PLAN.md` §8.4, which does not exist yet.
- A marketing site, landing page, or anything else at `castrtech.com` besides the app
  itself. Owning the domain settles where the app lives; it does not change the audience
  decision, and iteration 1 should not grow a front door for visitors who do not exist.

---

## 5. Phase W — the web app

No new tooling. Can start immediately. Each milestone is independently shippable
because `docs/` deploys on push.

### W0 — Move the site to castrtech.com *(before W1, not after)*

Ordering matters: W1 stores session history in IndexedDB, which is scoped to the
origin. Sessions saved at `nathanatbridge.github.io` stay there when the domain changes.
Move first and there is nothing to strand.

**DNS first, `CNAME` file second.** Setting a custom domain makes `nathanatbridge.github.io`
redirect to it, so a `CNAME` file committed while DNS still points at Squarespace takes
the site down at *both* addresses until DNS catches up. Do it in this order and there is
no window where nothing works:

1. Repoint DNS away from Squarespace. Apex needs GitHub's four `A` records; `www` needs
   a `CNAME` to `nathanatbridge.github.io`. **Take the addresses from GitHub's Pages
   documentation at the time** — they have changed before and a hardcoded list in a plan
   file is exactly the sort of thing that rots. If the domain is registered through
   Squarespace, its DNS panel is where this happens.
2. Wait for it to resolve — `dig +short castrtech.com` should return GitHub's addresses,
   not `198.49.23.144`.
3. Add `docs/CNAME` containing the bare hostname, and set the custom domain in the
   repository's Pages settings.
4. Wait for GitHub to provision the Let's Encrypt certificate, then turn on **Enforce
   HTTPS**. It cannot be enabled until the certificate exists, so this is a second visit.

**Settled 2026-08-06: the app is the apex.** `castrtech.com` serves it, `www` redirects
there. Not a subdomain — the audience is one person and the app *is* the site. The
alternative was reserving the apex for a landing page later, which §4 rules out anyway.
This was worth deciding up front rather than in W4 because of the stranded-history
problem above.

Note the site is already public at the `github.io` URL, so this changes the address, not
the exposure. Session data stays local to the browser either way — §3b.

### W1 — It remembers *(the biggest single gap)*

IndexedDB store holding, per session: the raw CSV text, the parsed summary, name, and
recording date. Library view listing every session — open, rename, delete. Drop the
two-session cap.

Raw text rather than parsed samples, because the parse is cheap and the raw file is the
thing that has to survive a change to `analysis.js`. `fish1.csv` is 4 MB; IndexedDB
handles that comfortably, `localStorage` would not.

**Browser storage is a cache, not a backup.** Clearing site data wipes it and it is
per-browser. See §8.

### W2 — Tag sidecars stop being an error

Recognise `<name>.events.csv` on drop and attach it to its recording rather than trying
to parse it as one. Draw taps as markers on the rotation trace.

**Markers only — do not port `TagMatcher` yet.** `PLAN.md` §4a shows delivery matching
currently binds 0 of 5 taps in `benchtest3`; porting it now would port a known defect
into a second implementation. Markers on the trace answer the question W2 actually asks
— *does seeing where I tagged tell me anything?* — for a fraction of the work.

### W3 — Decide what a session says *(the point of Phase W)*

Today the report is numbers, a trace, and a swing path. It has no verdict. This
milestone is where you find out what a caster wants to read after coming off the water,
and every screen it settles becomes an iOS screen in Phase I.

Candidates, to be cut down by use:

- **Bursts as the top-level unit.** Sequences, not a flat stroke list. The chips in the
  swing section already compute bursts; promote them to the report's spine.
- **Back/forward symmetry.** `netRotationDeg` is the strongest result in the project
  (`PLAN.md` §2 — 178 casts, one explained break). Nothing in the UI shows it. Signed
  arc per direction, and whether the two match.
- **Tempo** — the within-burst gaps, which `PLAN.md` §2 notes are 0.2–2.7 s.
- **Outliers.** Which stroke was unlike its neighbours, and where in the session.
- **A plain-language line at the top.** One sentence: how many casts, how consistent,
  what stood out.

Ship it, use it after a real session, cut whatever you did not read.

### W4 — Trends

With W1 storing history, replace A/B comparison with N-session trends: casts per
session, arc spread, tempo, symmetry, over time. This is the answer to "why open it
again next week", and it is the one thing a native app cannot borrow from the CLI.

---

## 6. Phase X — Xcode bring-up *(start now, runs in the background)*

The long pole. Blocks nothing in Phase W, so it should be in flight before W1 starts.

### X1 — Install Xcode

This machine is an **Intel** Core i5-8257U on macOS 15.4.1 with 122 GB free. Recent
Xcode releases are Apple-silicon-only — **check which is the last Intel-capable release
before downloading** rather than pulling the current one and finding out. Xcode 16.4 is
the expected answer; verify it against Apple's requirements, and confirm it can deploy
to whatever iOS version your iPhone runs.

`swift build` and `castr-selftest` must still pass afterwards. Installing Xcode moves
`xcode-select`'s active developer directory, which changes the toolchain the package
builds against.

### X2 — The app target

Per `README.md` §iOS app: new SwiftUI app project, add `CastrCore` and `CastrBLE` as
**local package dependencies** — not copied files, or the classifier stops arriving for
free and §3a's payoff is gone. Set `Privacy - Bluetooth Always Usage Description`.

Set the bundle identifier to `com.castrtech.castr` **now**, at creation, and do not
change it afterwards — §3d. Display name `Castr`.

Where the project file lives is a real decision: `ios/` alongside `Package.swift` keeps
one repo and one history. Take it.

### X3 — First compile

The first time any of `ios/` is type-checked. `README.md` says to expect breakage, and
the buttons and share sheet are the unverified part — the logic underneath them is in
`CastrCore`/`CastrBLE` and is covered by the 290 self-tests. Budget a session for this,
not an hour.

### X4 — Deploy and prove the recording is real

Record a short session on the phone and one on the Mac with `castr-collect`, then run
both through `castr-analyze`. The `CSVFormat` byte-parity claim in `CLAUDE.md` is
testable and this is the test: the phone's output must be indistinguishable in shape
from the Mac's, and healthy on the same terms `PLAN.md` §6 uses — ~1.000 g at rest, no
clipping, no negative timestamp deltas, zero rejected frames.

**Sign with the paid account ($99/yr), not a free Apple ID.** Free signing expires the
app after 7 days; it will die mid-trip, which is exactly when there is no Mac. This is
the one place iteration 1 costs money and it is worth it.

---

## 7. Phase I — the iOS app

### I0 — Field-hardening the recorder *(before any analysis UI)*

The recorder is worthless if it drops the session, so this comes first.

- **Disable the idle timer while recording.** `README.md`: no background modes are
  declared, so a locked screen stops the stream. The screen must stay awake.
- **Reconnect on BLE drop**, and make it visible in the file when it happened — a gap
  is data, a silent gap is a lie.
- **Rejected-frame count already surfaces** in `ContentView` (:172) and must stay
  surfaced. `CLAUDE.md`: it is the only signal that framing broke.
- Storage headroom and battery checks before a long session. `fish1` was 4 MB for 3
  minutes.

### I1 — On-device analysis

Link `StrokeAnalysis` and build the report Phase W settled on. No round trip to the Mac,
no export step to see results — this is the whole reason for the native app over the
existing recorder.

### I2 — Session library on device

Same model as W1: sessions persist, are listed, are openable. The share sheet already
exists in `ContentView` (:187) and must keep exporting the CSV **and its sidecar
together**, or the labels are lost.

### I3 — The classifier arrives

Nothing to build. As `PLAN.md` Stages 2–5 land in `CastrCore`, the app recompiles and
has them. Worth saying explicitly because it is the return on §3a and on refusing to
copy files in X2.

---

## 8. Risks, in order of what they would actually cost

**The recordings are not backed up.** `START-HERE.md`: ~13 MB, gitignored, existing
only in this folder, and a file already vanished once during the 2026-08-04 session with
the cause never identified. They cost trips outside with a rod and will not reproduce.
Everything in this plan increases how much handling they get. **Copy the corpus
somewhere durable before starting W1** — it is ten minutes and it is the only item here
that is unrecoverable if it goes wrong.

**`ios/` has never compiled.** Unknown breakage on an unknown surface. Mitigated only by
doing X3 early enough that a bad surprise does not land next to a deadline.

**The corpus is one caster, one rod, one mount orientation** (`PLAN.md` §6 caveat). The
app will bake in assumptions from it. The **mount-orientation test** — `PLAN.md` §8.1,
five minutes, remount the sensor rotated 90° and repeat a short sequence — can invalidate
the Stage 2 normalisation design. Do it before iOS analysis screens harden around the
current one.

**Browser storage is not durable, and it is origin-scoped.** W1 makes the web app feel
like it owns your history while the browser can drop it without asking — and clearing
site data, switching browsers, or changing the hostname all lose it independently. The
CSV files on disk stay canonical. W0 exists so the hostname is settled before there is
any history to strand.

**The app is only as interesting as the classifier.** A session report of arc degrees is
a spreadsheet with a chart. Knowing which stroke was which, and whether you are improving,
is what makes it worth carrying. `PLAN.md` does not pause for this document.

---

## 9. Sequencing

```
now      X1 install Xcode ──────────────────────┐ (background, hours)
now      back up the corpus                     │
now      mount-orientation test (5 min)         │
now      W0 castrtech.com + DNS ────┐           │ (DNS propagates, then HTTPS)
                                    ▼           │
week 1   W1 remembers                           │
         W2 sidecars                            │
                                                ▼
week 2   W3 what a session says            X2 bundle ID com.castrtech.castr
                                           X3 first compile
                                           X4 deploy + prove parity
week 3   W4 trends                         I0 field-hardening
                                           I1 on-device analysis
                                           I2 session library
                                           I3 classifier, as it lands
```

Timings are shape, not commitment. The hard orderings, all of them for the same reason —
something downstream starts storing data that will not move:

- **W0 before W1** — IndexedDB is per-origin.
- **X2's bundle ID before I2** — a changed bundle ID installs as a different app.
- X1 before X2, corpus backup before W1, W3 before I1, and the mount-orientation test
  before Stage 2 is designed against.

---

## 10. Iteration 1 is done when

You go fishing carrying only the phone and the sensor. You record and tag a session. You
read something useful about it before you leave the water. Those sessions accumulate,
and looking at last month next to this week tells you something you did not already know.

No laptop, no export step, no CSV in the middle.
