#!/usr/bin/env node
/* Asserts the browser analysis agrees with Swift's.
 *
 * Two implementations of the same maths will drift unless something checks.
 * This runs docs/analysis.js over a fixture recording and compares every
 * metric against the output of `castr-analyze --json` on the same file.
 *
 *   node tools/verify-web-parity.js
 *
 * Regenerate the fixture after an intentional change:
 *   swift run castr-selftest --emit-csv docs/fixtures/strokes.csv 5
 *   swift run castr-analyze docs/fixtures/strokes.csv --json \
 *     > docs/fixtures/strokes.expected.json
 */
"use strict";
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
require(path.join(root, "docs/analysis.js"));
const A = globalThis.CastrAnalysis;

const csvPath = path.join(root, "docs/fixtures/strokes.csv");
const expPath = path.join(root, "docs/fixtures/strokes.expected.json");

for (const p of [csvPath, expPath]) {
  if (!fs.existsSync(p)) {
    console.error(`missing fixture: ${path.relative(root, p)}`);
    console.error("regenerate it with the commands in this file's header.");
    process.exit(2);
  }
}

const expected = JSON.parse(fs.readFileSync(expPath, "utf8")).session;
const session = A.parseCSV(fs.readFileSync(csvPath, "utf8"), "strokes");
const strokes = A.analyze(session);

let failures = 0;
const near = (a, b, tol) => Math.abs(a - b) <= tol;

function check(label, actual, want, tol) {
  if (typeof want !== "number") { return; }
  if (near(actual, want, tol)) return;
  failures++;
  console.log(`  ✗ ${label}: swift ${want}, js ${actual} (tol ${tol})`);
}

console.log("web/Swift analysis parity\n");

// Session level
check("sample count", session.readings.length, expected.samples, 0);
check("duration", session.duration, expected.duration, 1e-3);
check("sample rate", session.sampleRateHz, expected.sampleRateHz, 0.05);

// Stroke count is the load-bearing one: a segmentation difference invalidates
// everything downstream, so report it loudly and stop.
if (strokes.length !== expected.strokes.length) {
  console.log(`  ✗ stroke count: swift ${expected.strokes.length}, js ${strokes.length}`);
  console.log("\nFAIL — segmentation differs; per-stroke comparison skipped.");
  process.exit(1);
}
console.log(`  ✓ segmentation agrees: ${strokes.length} strokes`);

// Tolerances reflect float formatting in the JSON (4 dp), not slack in the maths.
const FIELDS = [
  ["startTime", 2e-3], ["duration", 2e-3], ["arcDeg", 5e-3], ["pathDeg", 5e-3],
  ["planarityPct", 5e-3], ["offPlaneDeg", 5e-3], ["inPlanePct", 5e-3],
  ["peakRateDPS", 5e-3], ["peakRateAtPct", 5e-3],
  ["accelPhase", 2e-3], ["stopPhase", 2e-3],
  ["peakAccelDPS2", 0.05], ["peakDecelDPS2", 0.05], ["driveSmoothPct", 5e-3],
  ["stopSharePct", 5e-3], ["peakAccG", 5e-3], ["tempo", 5e-3]
];

strokes.forEach((s, i) => {
  const e = expected.strokes[i];
  FIELDS.forEach(([f, tol]) => check(`stroke ${i + 1} ${f}`, s[f], e[f], tol));
  if (s.dominantAxis !== e.dominantAxis) {
    failures++;
    console.log(`  ✗ stroke ${i + 1} dominantAxis: swift ${e.dominantAxis}, js ${s.dominantAxis}`);
  }
  if (s.samples !== e.samples) {
    failures++;
    console.log(`  ✗ stroke ${i + 1} samples: swift ${e.samples}, js ${s.samples}`);
  }
  // The signed rotation is what separates a back cast from a forward cast, so
  // a sign difference between the ports matters more than any magnitude here.
  "XYZ".split("").forEach((axis, k) => {
    check(`stroke ${i + 1} netRotationDeg ${axis}`,
          s.netRotationDeg[k], e.netRotationDeg[k], 5e-3);
  });
  // Whether a stroke *has* a stopping point is a decision, not a number: the
  // two ports agreeing on the value while disagreeing on which strokes have
  // one would leave the repeatability figures measured over different sets.
  if ((s.stopUp === null) !== (e.stopUp === null)) {
    failures++;
    console.log(`  ✗ stroke ${i + 1} stopUp presence: swift ${e.stopUp === null ? "none" : "yes"},`
                + ` js ${s.stopUp === null ? "none" : "yes"}`);
  } else if (s.stopUp) {
    "XYZ".split("").forEach((axis, k) => {
      check(`stroke ${i + 1} stopUp ${axis}`, s.stopUp[k], e.stopUp[k], 1e-4);
    });
    if (s.stopStillSamples !== e.stopStillSamples) {
      failures++;
      console.log(`  ✗ stroke ${i + 1} stopStillSamples: swift ${e.stopStillSamples},`
                  + ` js ${s.stopStillSamples}`);
    }
  }
  if (s.rateProfile.length !== e.rateProfile.length) {
    failures++;
    console.log(`  ✗ stroke ${i + 1} rateProfile length: swift ${e.rateProfile.length},`
                + ` js ${s.rateProfile.length}`);
  } else {
    s.rateProfile.forEach((v, k) =>
      check(`stroke ${i + 1} rateProfile[${k}]`, v, e.rateProfile[k], 5e-3));
  }
});
if (!failures) console.log(`  ✓ all ${FIELDS.length} metrics match on every stroke`);

// Spread statistics
const js = A.spreads(strokes);
js.forEach((sp, i) => {
  const e = expected.spreads[i];
  if (!e) return;
  if (sp.name !== e.name) {
    failures++;
    console.log(`  ✗ spread ${i} name: swift ${e.name}, js ${sp.name}`);
    return;
  }
  check(`spread ${sp.name} mean`, sp.mean, e.mean, 5e-3);
  check(`spread ${sp.name} sd`, sp.sd, e.sd, 5e-3);
  check(`spread ${sp.name} cv`, sp.cvPct, e.cvPct, 5e-3);
});
if (!failures) console.log("  ✓ spread statistics match");

const rep = A.repeatabilityCV(strokes);
check("repeatability CV", rep, expected.repeatabilityCV, 5e-3);

// Repeatability of shape and position. These are what a caster reads the page
// for, so a port that drifts here is worse than one that drifts on a spread —
// the numbers still look plausible and no longer mean the same thing.
const jsRep = A.repeatability(strokes);
const swRep = expected.repeatability;

check("casts counted", jsRep.castCount, swRep.castCount, 0);
check("strokes set aside", jsRep.setAside, swRep.setAside, 0);
check("stops unmeasured", jsRep.stopsUnmeasured, swRep.stopsUnmeasured, 0);

function checkAngular(js, sw, label) {
  if (!js !== !sw) {
    failures++;
    console.log(`  ✗ ${label}: swift ${sw ? "present" : "absent"}, js ${js ? "present" : "absent"}`);
    return;
  }
  if (!js) return;
  if (js.name !== sw.name) {
    failures++;
    console.log(`  ✗ ${label} name: swift ${sw.name}, js ${js.name}`);
  }
  check(`${label} count`, js.count, sw.count, 0);
  check(`${label} meanDeg`, js.meanDeg, sw.meanDeg, 5e-3);
  check(`${label} sdDeg`, js.sdDeg, sw.sdDeg, 5e-3);
  check(`${label} maxDeg`, js.maxDeg, sw.maxDeg, 5e-3);
  if (js.worstStroke !== sw.worstStroke) {
    failures++;
    console.log(`  ✗ ${label} worstStroke: swift ${sw.worstStroke}, js ${js.worstStroke}`);
  }
}

checkAngular(jsRep.plane, swRep.plane, "plane spread");
if (jsRep.stops.length !== swRep.stops.length) {
  failures++;
  console.log(`  ✗ stop groups: swift ${swRep.stops.length}, js ${jsRep.stops.length}`);
} else {
  jsRep.stops.forEach((g, i) => checkAngular(g, swRep.stops[i], `stops[${i}]`));
}
if (jsRep.drive.length !== swRep.drive.length) {
  failures++;
  console.log(`  ✗ drive groups: swift ${swRep.drive.length}, js ${jsRep.drive.length}`);
} else {
  jsRep.drive.forEach((g, i) => {
    const e = swRep.drive[i];
    if (g.name !== e.name) {
      failures++;
      console.log(`  ✗ drive[${i}] name: swift ${e.name}, js ${g.name}`);
    }
    check(`drive[${i}] count`, g.count, e.count, 0);
    check(`drive[${i}] meanDeviationPct`, g.meanDeviationPct, e.meanDeviationPct, 5e-3);
    check(`drive[${i}] agreementPct`, g.agreementPct, e.agreementPct, 5e-3);
    check(`drive[${i}] maxDeviationPct`, g.maxDeviationPct, e.maxDeviationPct, 5e-3);
  });
}

// The direction split decides which strokes each group is measured over, so it
// has to agree before any of the figures above mean the same thing.
const jsFrame = A.castingFrame(A.casts(strokes));
if (jsFrame && swRep.directions) {
  if (jsFrame.signs.join(",") !== swRep.directions.join(",")) {
    failures++;
    console.log(`  ✗ directions: swift [${swRep.directions}], js [${jsFrame.signs}]`);
  }
  "XYZ".split("").forEach((axis, k) =>
    check(`casting axis ${axis}`, jsFrame.axis[k], swRep.castingAxis[k], 1e-4));
}
if (!failures) console.log("  ✓ repeatability of shape and position matches");

console.log("");
if (failures) {
  console.log(`FAIL — ${failures} mismatch${failures === 1 ? "" : "es"}`);
  process.exit(1);
}
console.log("PASS — browser analysis matches Swift");
