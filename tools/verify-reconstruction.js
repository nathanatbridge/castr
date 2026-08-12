#!/usr/bin/env node
/* Asserts the swing-path reconstruction recovers what it should.
 *
 * The parity check keeps the browser analysis honest against Swift. This does
 * the other half: the reconstruction has no Swift counterpart to compare
 * against, so it is checked against ground truth instead. The fixture is
 * generated from a known lever arm and a known gyro bias, so both must come
 * back out of the CSV.
 *
 *   node tools/verify-reconstruction.js
 *
 * Regenerate the fixtures after an intentional change:
 *   swift run castr-selftest --emit-csv docs/fixtures/strokes.csv 5
 *   swift run castr-selftest --emit-axis-fixture docs/fixtures/rod-axis.json
 *
 * The rod-axis fixture does double duty. MountCalibration.swift is the
 * authority for the axis solve and reconstruct.js carries a mirror of it, so
 * this is the parity check for that pair — the role verify-web-parity.js plays
 * for the analysis, done with a fixture instead of a CLI because
 * `castr-analyze` has no calibration input to compare through.
 *
 * The ground truth below is set in Sources/castr-selftest/FixtureRod.swift.
 * Change it there and change it here.
 */
"use strict";
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
require(path.join(root, "docs/analysis.js"));
require(path.join(root, "docs/reconstruct.js"));
const A = globalThis.CastrAnalysis;
const R = globalThis.CastrReconstruct;

/* --- ground truth, from the fixture generator --- */
const ARM_BODY = [0.08, -0.10, -0.26];      // metres, in the sensor's own frame
const AXIS     = [1, 0.04, -0.02];          // the fixture turns about this direction
const BIAS     = [0.3, -0.2, 0.1];          // °/s

/* The rod, from FixtureRod.swift. Unlike the arm these leave no trace in the
   CSV — the tip is projected after the fit, not fitted — so they are ground
   truth for the projection rather than something to recover from the data. */
const ROD_AXIS = unit([0.31, -0.36, -0.88]); // butt -> tip, sensor's frame
const TIP_M    = 2.44;                       // sensor to tip
// What a level hold reads: the sensor's up direction, square to the blank.
const LEVEL_UP = (() => {
  const seed = Math.abs(ROD_AXIS[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0];
  return unit([ROD_AXIS[1]*seed[2] - ROD_AXIS[2]*seed[1],
               ROD_AXIS[2]*seed[0] - ROD_AXIS[0]*seed[2],
               ROD_AXIS[0]*seed[1] - ROD_AXIS[1]*seed[0]]);
})();

function unit(v) {
  const n = Math.hypot(...v);
  return v.map(c => c / n);
}

/* Only the part of the arm perpendicular to the rotation axis is observable:
   w x (w x r) and alpha x r both annihilate the component along w. So that is
   what the reconstruction can be asked to return. */
function observableArmVector() {
  const n = unit(AXIS);
  const dot = ARM_BODY.reduce((s, c, i) => s + c * n[i], 0);
  return ARM_BODY.map((c, i) => c - dot * n[i]);
}
function observableArm() {
  return Math.hypot(...observableArmVector());
}

/* Where the tip sits relative to the pivot, given the arm the reconstruction
   can actually see. The unobservable slice of the arm is missing from both, so
   this is what the tip radius should come back as — not |ARM_BODY + L*axis|. */
function observableTipRadius() {
  const arm = observableArmVector();
  return Math.hypot(...arm.map((c, i) => c + TIP_M * ROD_AXIS[i]));
}

const csvPath = path.join(root, "docs/fixtures/strokes.csv");
if (!fs.existsSync(csvPath)) {
  console.error("missing fixture: " + path.relative(root, csvPath));
  console.error("regenerate it with the command in this file's header.");
  process.exit(2);
}

let failures = 0;
function check(label, actual, want, tol, unit) {
  const ok = Math.abs(actual - want) <= tol;
  if (!ok) failures++;
  const u = unit || "";
  console.log(`  ${ok ? "✓" : "✗"} ${label}: ${actual.toFixed(3)}${u}` +
              (ok ? ` (want ${want.toFixed(3)}${u} ±${tol}${u})`
                  : `  EXPECTED ${want.toFixed(3)}${u} ±${tol}${u}`));
}

console.log("swing-path reconstruction against ground truth\n");

const session = A.parseCSV(fs.readFileSync(csvPath, "utf8"), "strokes");
const spans = A.detectStrokes(session.readings);
const rec = R.reconstruct(session.readings, spans);

// Gyro bias must be measured back out of the still periods.
["X", "Y", "Z"].forEach((ax, i) => {
  check("gyro bias " + ax, rec.bias[i], BIAS[i], 0.02, " °/s");
});

const fitted = rec.bursts.filter(b => b.ok);
if (fitted.length !== 1) {
  console.log(`  ✗ expected exactly one fitted burst, got ${fitted.length} ` +
              `of ${rec.bursts.length}`);
  rec.bursts.forEach(b => console.log(`      burst ${b.index}: ` +
    (b.ok ? "fitted" : "rejected — " + b.reason)));
  failures++;
} else {
  const b = fitted[0];
  console.log(`  ✓ one burst fitted, covering ${b.strokes.length} strokes`);

  // The lever arm is the point of the whole exercise.
  check("lever arm", b.armCm, observableArm() * 100, 0.5, " cm");

  // The fixture is exactly a rigid arm, so the model should explain nearly all
  // of it. Anything above a few percent means the maths has drifted.
  check("residual", b.residual, 0, 0.05);

  // The fixture rotates about one axis, so the path must stay in its plane.
  if (b.outOfPlaneCm > 3) {
    console.log(`  ✗ out of plane: ${b.outOfPlaneCm.toFixed(2)} cm — should be planar`);
    failures++;
  } else {
    console.log(`  ✓ path stays planar: ${b.outOfPlaneCm.toFixed(2)} cm out of plane`);
  }

  // The fixture is deliberately NOT an alternating sequence: it is a run of
  // same-direction bells followed by one reversal, so that direction detection
  // is tested against something other than the alternating case. Anything that
  // reports it as alternating is reading the sweep of the path rather than the
  // rotation — those differ, because a run of same-direction strokes carries
  // the sensor right around the pivot and the sweep flips over the top.
  const signs = b.segs.map(s => (s.dir > 0 ? "+" : "-")).join("");
  const head = signs.slice(0, -1), tail = signs.slice(-1);
  const uniform = [...head].every(c => c === head[0]);
  if (!uniform || tail === head[0]) {
    console.log(`  ✗ stroke directions: ${signs} — expected a same-direction run ` +
                `then one reversal`);
    failures++;
  } else {
    console.log(`  ✓ stroke directions: ${signs} — ${head.length} one way, ` +
                `then the reversal`);
  }
}

/* --- the rod tip projection --- */

console.log("\nrod tip projection\n");

const withRod = R.reconstruct(session.readings, spans, {
  rod: { tipFromSensorM: TIP_M, axisBody: ROD_AXIS }
});
const rodBurst = withRod.bursts.filter(b => b.ok);

if (rodBurst.length !== 1 || !rodBurst[0].tip) {
  console.log("  ✗ expected one fitted burst carrying a tip path");
  failures++;
} else {
  const b = rodBurst[0];
  if (!b.tip.ok) {
    console.log(`  ✗ tip refused: ${b.tip.reason}`);
    failures++;
  } else {
    check("tip radius", b.tip.radiusCm, observableTipRadius() * 100, 0.5, " cm");

    // The tip is the same rigid body as the sensor, so the vector between them
    // is constant and exactly as long as the rod. If the two paths had gone
    // through different frames — a heading rotation applied to one and not the
    // other, or a sign flip on only one — this is what would catch it, and it
    // is the reason both go through a single `toFrame`.
    let worstOffset = 0;
    for (let k = 0; k < b.pts.length; k++) {
      const d = Math.hypot(b.tip.pts[k][0] - b.pts[k][0],
                           b.tip.pts[k][1] - b.pts[k][1],
                           b.tip.pts[k][2] - b.pts[k][2]);
      worstOffset = Math.max(worstOffset, Math.abs(d - TIP_M));
    }
    check("sensor-to-tip offset holds over the whole path", worstOffset, 0, 1e-9, " m");

    // The fixture turns about one axis, so the tip stays in its plane too —
    // but "planar" cannot mean the same number of centimetres out there as at
    // the sensor. The tip sits ten times further from the pivot, so the
    // sensor's own 1.1 cm of wander is 10 cm at the tip before anything has
    // gone wrong. What must hold is that the tip adds no wander of its own:
    // the *angular* departure from the plane is the same at both radii,
    // because the projection is geometry rather than a second estimator.
    const sensorSpread = b.outOfPlaneCm / b.armCm;
    const tipSpread = b.tip.outOfPlaneCm / b.tip.radiusCm;
    if (tipSpread > sensorSpread * 1.1) {
      console.log(`  ✗ tip departs its plane by ${(tipSpread * 100).toFixed(2)}% of ` +
                  `its radius against the sensor's ${(sensorSpread * 100).toFixed(2)}% ` +
                  `— the projection is adding error of its own`);
      failures++;
    } else {
      console.log(`  ✓ tip stays as planar as the sensor does ` +
                  `(${b.tip.outOfPlaneCm.toFixed(1)} cm at ${b.tip.radiusCm.toFixed(0)} cm ` +
                  `radius vs ${b.outOfPlaneCm.toFixed(1)} cm at ${b.armCm.toFixed(0)} cm)`);
    }

    // The point of drawing the tip at all: the same motion is an order of
    // magnitude bigger out there than at the handle.
    const gain = b.tip.extentCm / b.extentCm;
    if (gain < 3) {
      console.log(`  ✗ tip extent is only ${gain.toFixed(1)}x the sensor's — ` +
                  `expected the rod to amplify it`);
      failures++;
    } else {
      console.log(`  ✓ tip travels ${b.tip.extentCm.toFixed(0)} cm against the ` +
                  `sensor's ${b.extentCm.toFixed(0)} cm (${gain.toFixed(1)}x)`);
    }

    const segsWithTip = b.segs.filter(s => s.tipOutOfPlaneCm !== undefined).length;
    check("per-stroke tip figures", segsWithTip, b.segs.length, 0, " strokes");
  }
}

// The stopping point, reached two independent ways.
//
// CastrAnalysis reads gravity off a still moment and carries it back across the
// gyro; the reconstruction carries orientation forward from the still window
// before the burst. On this fixture both are exact, so they have to land in the
// same place, and a drift in either implementation shows up here.
//
// On real recordings they don't: measured across the corpus the two sit a
// median 7.3° apart, 20° at the ninth decile, with no trend in elapsed time —
// gyro scale error over a burst's whole integrated path. That is why the
// reported stopping point is the gravity one and not this one. PLAN.md §10.
if (fitted.length === 1) {
  const strokes = A.analyze(session);
  let worst = 0, compared = 0;
  for (const seg of fitted[0].segs) {
    const m = strokes[seg.stroke];
    if (!m || !m.stopUp || !seg.stopUpBody) continue;
    const d = m.stopUp[0] * seg.stopUpBody[0]
            + m.stopUp[1] * seg.stopUpBody[1]
            + m.stopUp[2] * seg.stopUpBody[2];
    worst = Math.max(worst, Math.acos(Math.min(1, Math.max(-1, d))) * 180 / Math.PI);
    compared++;
  }
  if (compared < 2) {
    console.log(`  ✗ only ${compared} stroke(s) had a stopping point both ways`);
    failures++;
  } else {
    // Even here they are not identical: the reconstruction integrates the
    // burst's whole path to reach each stop while the gravity reading is
    // carried back a fraction of a second, and that costs 2.0° at the worst
    // stroke on an otherwise exact fixture. It is the same error that grows to
    // 7.3° on real recordings, seen small. The bound is set just above it —
    // anything much larger is a port that has diverged, not integration.
    check(`stopping point agrees both ways (${compared} strokes)`, worst, 0, 3.0, "°");
  }
}

// No rod, no tip — an absent projection rather than a guessed one.
if (fitted.length === 1 && fitted[0].tip === null) {
  console.log("  ✓ without rod geometry no tip is reported");
} else {
  console.log("  ✗ a tip was reported without rod geometry");
  failures++;
}

// Incomplete geometry is refused with a reason, not silently ignored.
const noAxis = R.reconstruct(session.readings, spans, { rod: { tipFromSensorM: TIP_M } });
const noAxisTip = noAxis.bursts.filter(b => b.ok)[0].tip;
if (noAxisTip && !noAxisTip.ok && /axis/.test(noAxisTip.reason)) {
  console.log(`  ✓ a rod with no axis is refused — "${noAxisTip.reason}"`);
} else {
  console.log("  ✗ a rod with no axis should be refused with a reason");
  failures++;
}

// The browser hands over calibration holds rather than a solved axis, so that
// path has to land in the same place as passing the axis directly.
const viaHolds = R.reconstruct(session.readings, spans, {
  rod: {
    tipFromSensorM: TIP_M,
    holds: { vertical: [ROD_AXIS.map(c => c * 1.01), ROD_AXIS],
             level: [LEVEL_UP.map(c => c * 0.99)] }
  }
});
const holdsTip = viaHolds.bursts.filter(b => b.ok)[0].tip;
const directTip = rodBurst.length ? rodBurst[0].tip : null;
if (holdsTip && holdsTip.ok && directTip && directTip.ok &&
    Math.abs(holdsTip.radiusCm - directTip.radiusCm) < 1e-9) {
  console.log("  ✓ solving the axis from holds matches passing it directly");
} else {
  console.log("  ✗ the holds path and the axis path disagree");
  failures++;
}

// The tip amplifies orientation error about elevenfold, so it does not accept
// the fallback gravity reference the sensor path tolerates. Slicing the leading
// rest away leaves the first burst with nothing to anchor against.
const firstStroke = spans[0][0];
const unanchored = { readings: session.readings.slice(firstStroke) };
const unanchoredSpans = A.detectStrokes(unanchored.readings);
const unanchoredRec = R.reconstruct(unanchored.readings, unanchoredSpans, {
  rod: { tipFromSensorM: TIP_M, axisBody: ROD_AXIS }
});
const ungrounded = unanchoredRec.bursts.filter(b => b.ok && !b.grounded);
if (!ungrounded.length) {
  console.log("  ✗ expected an ungrounded burst to test the tip refusal against");
  failures++;
} else if (ungrounded.every(b => b.tip && !b.tip.ok && /not anchored/.test(b.tip.reason))) {
  console.log("  ✓ an unanchored burst still draws its arm but refuses a tip");
} else {
  console.log("  ✗ an unanchored burst must not draw a tip path");
  failures++;
}

/* --- the rod axis solve, against Swift --- */

console.log("\nrod axis, against MountCalibration.swift\n");

const axisPath = path.join(root, "docs/fixtures/rod-axis.json");
if (!fs.existsSync(axisPath)) {
  console.error("missing fixture: " + path.relative(root, axisPath));
  console.error("regenerate it with the command in this file's header.");
  process.exit(2);
}
const axisFixture = JSON.parse(fs.readFileSync(axisPath, "utf8"));

for (const c of axisFixture.cases) {
  const got = R.rodAxis(c.vertical, c.level, axisFixture.maxSpreadDeg);
  if (got.ok !== c.ok) {
    console.log(`  ✗ ${c.name}: Swift says ok=${c.ok}, JS says ok=${got.ok}`);
    failures++;
    continue;
  }
  if (!c.ok) {
    if (got.reason !== c.reason) {
      console.log(`  ✗ ${c.name}: reason differs\n      Swift: ${c.reason}` +
                  `\n      JS:    ${got.reason}`);
      failures++;
    } else {
      console.log(`  ✓ ${c.name}: both refuse — "${got.reason}"`);
    }
    continue;
  }
  // acos is ill-conditioned near its endpoints: two identical unit vectors can
  // differ by 1e-13 in the dot product and come out 6e-7 degrees apart. That is
  // 4e-7 cm at the tip of a 9 ft rod, so the bound is set where the arithmetic
  // lives rather than where it would look impressive.
  const near = (a, b) => (a === null || b === null) ? a === b : Math.abs(a - b) <= 1e-5;
  const drift = Math.max(...got.axis.map((v, i) => Math.abs(v - c.axis[i])));
  const agree = drift <= 1e-9 && near(got.errorDeg, c.errorDeg) &&
                near(got.levelCheckDeg, c.levelCheckDeg) &&
                near(got.levelSpreadDeg, c.levelSpreadDeg);
  if (!agree) {
    console.log(`  ✗ ${c.name}: axis drift ${drift.toExponential(2)}, ` +
                `error ${got.errorDeg} vs ${c.errorDeg}, ` +
                `levelCheck ${got.levelCheckDeg} vs ${c.levelCheckDeg}`);
    failures++;
  } else {
    const bar = got.errorDeg === null ? "no error bar" : `±${got.errorDeg.toFixed(1)}°`;
    console.log(`  ✓ ${c.name}: matches Swift (${bar})`);
  }
}

// The two properties this rewrite exists for, asserted rather than only
// commented. A sloppy *level* hold must not cost a good axis — that is the
// failure that made the calibration feel impossible to pass.
const loose = axisFixture.cases.find(c => /not refused/.test(c.name));
if (loose) {
  if (loose.ok && loose.levelCheckDeg > 10 && loose.errorDeg < 0.01) {
    console.log(`  ✓ a level hold ${loose.levelCheckDeg.toFixed(0)}° out of level is ` +
                `reported, and the axis still stands`);
  } else {
    console.log("  ✗ a sloppy level hold is still costing the axis");
    failures++;
  }
}
// And a consistent lean across both vertical holds still cannot be seen.
const lean = axisFixture.cases.find(c => /consistent lean/.test(c.name));
if (lean) {
  const off = Math.acos(Math.min(1, Math.max(-1,
    lean.axis.reduce((s, v, i) => s + v * axisFixture.trueAxisBody[i], 0)))) * 180 / Math.PI;
  if (lean.errorDeg < 0.01 && off > 2.5) {
    console.log(`  ✓ a lean repeated in both holds reports ±0.0° while being ` +
                `${off.toFixed(1)}° wrong — the bar is a floor, not a bound`);
  } else {
    console.log("  ✗ the consistent-lean case no longer demonstrates the blind spot");
    failures++;
  }
}

console.log("");

// A physically impossible session must be refused rather than drawn. Scaling
// acceleration to nonsense keeps the rotation intact, so it still segments into
// strokes — but no rigid arm explains it.
const bogus = A.parseCSV(fs.readFileSync(csvPath, "utf8"), "bogus");
bogus.readings.forEach(r => { r.ax = 0.01 + Math.abs(r.gx) / 900; r.ay = -0.02; r.az = 1; });
const bogusRec = R.reconstruct(bogus.readings, A.detectStrokes(bogus.readings));
if (bogusRec.bursts.some(b => b.ok)) {
  console.log("  ✗ fabricated acceleration was accepted and would be drawn as a path");
  failures++;
} else {
  console.log("  ✓ fabricated acceleration is refused, not drawn");
}

console.log("");
if (failures) {
  console.log(`FAIL — ${failures} check${failures === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("PASS — reconstruction recovers the fixture's arm, bias and geometry");
