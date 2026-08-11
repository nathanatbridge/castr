# Castr console — plan

One localhost page that runs the pre-session calibration, records a session, and drops
the finished recording straight into the analyser. The CSV still lands on disk first,
every time — the console is a front end to `castr-collect`, not a replacement pipeline.

Read `CLAUDE.md` for build mechanics, `CAPTURE.md` for the protocol this page automates,
`PLAN.md` for the analysis work it feeds.

---

## The one architectural decision

**Serve `docs/` itself. Do not build a replica of the GitHub analyser.**

A second copy of the analyser is a second thing to keep in step with `StrokeAnalysis.swift`,
and `verify-web-parity.js` only checks one of them. The local server serves the real
`docs/index.html`, `analysis.js` and `reconstruct.js` off disk. The console is an extra
panel inside that page which appears only when `GET /api/health` answers — from GitHub
Pages it does not, the panel stays hidden, and the published analyser behaves exactly as
it does today.

Consequences worth naming up front:

- `docs/` stays analysis-only with no BLE in it. Bluetooth lives in the Swift server;
  the page talks HTTP. The constraint in `CLAUDE.md` survives as written.
- Editing the analyser once fixes it in both places. Parity tooling keeps its meaning.
- Recording is still `CaptureSession` → `CSVWriter`, so `CSVFormat` byte-parity is
  untouched and tags still go to the sidecar.

**Rejected: Web Bluetooth in the browser.** The WT901BLE's FFE5/FFE4 service is reachable
from Chrome, but it would mean a JS port of `FrameParser`, the glitch filter and the
saturation counter — a third implementation of the decode path, checked by nothing, and
Chrome-only. The Swift decoder already works and is covered by 290 selftest checks.

---

## Stages

### Stage A — extract the capture core *(no visible change)*

`Collector` currently mixes three jobs: driving BLE, owning capture state, and painting a
terminal. Only the middle one is reusable.

- New library target **`CastrCapture`** (depends on `CastrCore` + `CastrBLE`) holding
  `CaptureSession`: writer, `GlitchFilter`, `SaturationCounter`, `EventLogWriter`,
  check-mode sample buffer, and a `CaptureStatus` snapshot struct (state, samples,
  effective Hz, latest reading, rejected frames, tag count, last tag).
- It reports through a delegate/callback and **never calls `exit()`**. Shutdown returns a
  `CaptureResult` — paths written, counts, saturation report, `StaticCheck.Result` when in
  check mode.
- `Collector` becomes a thin terminal renderer over it. `castr-collect` output stays
  byte-identical; that is the acceptance test.
- Free win while in here: **`PLAN.md` §4b**. `CaptureSession` knows when the first sample
  arrived, so taps that precede it get held and reported instead of written silently.

Tests in `castr-selftest`: drive `CaptureSession` from `SyntheticSource` replay bytes,
assert the status snapshots and that the written CSV matches the existing fixture.

### Stage B — `castr-serve`

New executable target. `NWListener` (Network.framework ships with the OS — zero
third-party stays zero) speaking HTTP/1.1 with keep-alive and SSE.

```
castr-serve [--port 8787] [--docs ./docs] [--sessions .] [--open]
```

Binds **127.0.0.1 only**, and rejects any request carrying an `Origin` that isn't
localhost — a two-line DNS-rebinding guard, cheap and worth having on a server that can
start a Bluetooth scan.

| endpoint | does |
|---|---|
| `GET /` and `/*.js`, `/*.css`, `/fixtures/*` | static, from `--docs` |
| `GET /api/health` | `{version, sessionsDir}` — the feature flag the page detects on |
| `GET /api/status` | SSE, `CaptureStatus` at 5 Hz |
| `POST /api/check` | run the `--check` window, return `StaticCheck.Result` as JSON |
| `POST /api/record` | `{name, rate, despike, tags}` → starts; 409 if one is running |
| `POST /api/tag` | `{label}`, stamped on arrival |
| `POST /api/stop` | returns `CaptureResult` |
| `GET /api/sessions` | CSVs in the sessions dir |
| `GET /api/sessions/<name>.csv` | raw text, path-sanitised |
| `GET /api/analyze?session=` | `Report.json(...)` in-process — same output as `castr-analyze --json` |

One capture at a time, guarded by the same lock `CaptureSession` already uses. Tag
timestamps take a ~1 ms localhost hop, which is three orders of magnitude below the
reaction lag §4a is about — not a concern, but say so in a comment so nobody re-derives it.

### Stage C — the console panel

`docs/console.js`, plus a `<section id="console" class="hidden">` in `index.html` that is
revealed only after `/api/health` answers.

**Calibrate.** `CAPTURE.md`'s pre-session checklist as steps — mount position and *the
same rotational orientation*, which is the one that silently ruins cross-session
comparison. Then a Run health check button → `POST /api/check` → the four verdict lines
(stillness / gravity / axes / framing) rendered with the CLI's exact wording and the same
pass/warn/fail thresholds, because two wordings for one measurement is how you end up
trusting the wrong one.

**Record.** Name field validating `<person>-<test>` from `CAPTURE.md` naming, rate,
despike, tags on/off. Live status from the SSE stream: samples, Hz, `|acc|`, **rejected**
(always shown, per the hard constraint), tag count. Tag buttons `1`–`4` wired to the
keyboard as well — the tagger is watching the caster, not the screen.

**Analyse.** On stop: fetch the CSV that was just written and hand the text to the page's
existing `addSession(text, name)`. Same function the file picker uses, same analysis, no
new path. That is the "in the analyser the moment the motion ends" part, and it works
because the file is already on disk — the console reads it back rather than holding it in
memory, so what you analyse is provably what was saved.

### Stage D — labels in the local page

The published analyser ignores tag sidecars (it has no port of `TagMatching`), and that
stays true. Locally, `GET /api/analyze` returns the real Swift `BY LABEL` section, rendered
as a section that exists only in local mode. Right answer for free, no second matcher.

### Stage E — live trace *(optional)*

SSE carries a decimated rotation-rate series so the strip and trace canvases draw during
the recording. Genuinely useful for spotting a rod drifting out of plane during a
`-updown` run, but it is polish — everything above works without it.

### Stage F — parity, tests, docs

- `swift run castr-selftest` and `node tools/verify-web-parity.js` unchanged and green.
- New `tools/verify-console-api.js`: boot `castr-serve` against `--replay`, walk
  check → record → stop → analyze, assert the JSON. No hardware, CI-able.
- `CLAUDE.md` layout section, `CAPTURE.md` gains a console column beside each command,
  `README.md` a short section.

### Stage G — double-click launch *(this is the point of the exercise)*

Stages A–F still leave you typing `swift run castr-serve`, which is not "no terminal".

Build **`Castr.app`** — a hand-assembled bundle, which needs no Xcode because an `.app` is
just a directory layout:

```
Castr.app/Contents/
  Info.plist          NSBluetoothAlwaysUsageDescription, LSUIElement
  MacOS/castr-serve   the release binary
  Resources/docs/     analysis.js, reconstruct.js, index.html
```

`tools/make-app.sh` does `swift build -c release`, copies, and ad-hoc signs with
`codesign --sign -` (Command Line Tools has `codesign`). Double-click → server starts on a
free port → default browser opens to it. Quit is a button in the page hitting
`POST /api/quit`, because an `LSUIElement` bundle has no menu bar to quit from.

Two things this fixes that are not cosmetic:

- **Bluetooth permission.** A real bundle with a real `NSBluetoothAlwaysUsageDescription`
  gets a proper prompt and a stable, re-grantable entry in System Settings → Privacy →
  Bluetooth. That is strictly better than the `-sectcreate __TEXT __info_plist` hack
  `castr-collect` needs (`Package.swift`), which exists to stop CoreBluetooth returning
  `.unauthorized` *silently* to a bare CLI binary.
- **Sleep.** Closing the lid to walk somewhere kills the BLE link. The app holds an
  `NSProcessInfo.beginActivity(.idleSystemSleepDisabled)` for the duration of a recording —
  something the terminal workflow never did.

---

## Order

A → B → C gets the whole loop working; **G is what makes it worth having**, so do it right
after C and before D/E/F. A is the only stage with a regression risk worth taking slowly,
because `castr-collect` has to come out the far side identical.

---

## Is it reliable?

Split the question, because the answer differs sharply between the two halves.

**The recording path: yes, and it is not new.** `BLESession` → `FrameParser` →
`GlitchFilter` → `CSVWriter` is untouched — the same code behind 290 selftest checks and
fourteen recorded sessions. The console starts and stops it; it does not reimplement it.
Three properties carry over unchanged:

- The CSV streams to disk continuously, so a crash mid-session leaves a valid file.
- `rejected` is surfaced at all times, which is the only signal that framing broke.
- **The browser is a viewer, not a recorder.** Close the tab, throttle it, let Chrome
  suspend it in the background — the capture is in the server and keeps running. This is
  the main reason not to put Bluetooth in the page.

**The launcher and permissions: this is where the new failure modes live.** All four are
startup failures, which is the good place for them — they happen in the kitchen, loudly,
before you have driven anywhere:

| failure | mitigation |
|---|---|
| Bluetooth `.unauthorized` with no prompt | real `.app` bundle (Stage G); page shows the state, never a blank scan |
| stale server from a previous run holding the port | probe `/api/health` on launch, reuse it instead of failing |
| unsigned-app quarantine on first open | `make-app.sh` ad-hoc signs; document the one-time right-click → Open |
| hand-rolled HTTP bugs | narrow surface, localhost-only, `verify-console-api.js` walks it |

**The honest summary:** this is *more* moving parts than `castr-collect -o dad-20ft.csv`,
so it is not more reliable in the absolute. It is more convenient, and it relocates the
failures from mid-session to launch. That trade is worth it, on two conditions:

1. **`castr-collect` keeps working, forever.** It is the fallback for the day the app will
   not open in a field with no signal. Keep one known-good command line written down.
2. **The health check runs from the console before every session**, exactly as
   `CAPTURE.md` already demands. Convenience must not become a reason to skip it.

Nothing here needs the internet. It is localhost, offline, in a field, all of it.

## Decisions taken as default — say so if you disagree

- **The CLI stays canonical.** `castr-collect` keeps working standalone and is what a
  session in the field uses if the console is in the way.
- **Sessions default to the repo root**, where the corpus already lives; `--sessions`
  moves it.
- **Replay mode is exposed in the console** (`--replay` fixture as a fake sensor), so the
  page can be developed and demoed with no sensor charged.
- **The console does not add metrics.** Everything it shows comes from `StaticCheck`,
  `CaptureStatus` or the existing analyser.

## What this does not do

Nothing here touches segmentation, classification, or the `PLAN.md` roadmap, except
§4b falling out of Stage A. It removes friction from capture; the analysis questions are
unchanged. It also cannot make the iOS app buildable — Xcode is still not installed.
