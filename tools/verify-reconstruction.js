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
 * Regenerate the fixture after an intentional change:
 *   swift run castr-selftest --emit-csv docs/fixtures/strokes.csv 5
 *
 * The ground truth below is set in Sources/castr-selftest/main.swift. Change it
 * there and change it here.
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

/* Only the part of the arm perpendicular to the rotation axis is observable:
   w x (w x r) and alpha x r both annihilate the component along w. So that is
   what the reconstruction can be asked to return. */
function observableArm() {
  const m = Math.hypot(...AXIS);
  const n = AXIS.map(c => c / m);
  const dot = ARM_BODY.reduce((s, c, i) => s + c * n[i], 0);
  return Math.hypot(...ARM_BODY.map((c, i) => c - dot * n[i]));
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
