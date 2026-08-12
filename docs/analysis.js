/* Castr analysis — browser port of Sources/CastrCore/StrokeAnalysis.swift.
 *
 * Swift is the source of truth. This exists so a recording can be analysed in
 * the browser without installing anything, and without the file leaving the
 * machine. The two are kept honest by tools/verify-web-parity.js, which runs
 * this code over a fixture and asserts it matches Swift's own output.
 *
 * If you change the maths here, change it in Swift too and re-run the parity
 * check — or the web report and the CLI will quietly disagree.
 */
(function (root) {
  "use strict";

  var REQUIRED = ["time", "AccX(g)", "AccY(g)", "AccZ(g)", "AsX(°/s)", "AsY(°/s)", "AsZ(°/s)"];

  /* ---------- CSV ---------- */

  // Parsed by hand rather than with Date(): the format is fixed and local, and
  // Date's handling of space-separated stamps varies between engines.
  var TS = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?$/;
  function parseTime(s) {
    var m = TS.exec(s.trim());
    if (!m) return NaN;
    var frac = m[7] ? parseFloat("0." + m[7]) : 0;
    return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime() + frac * 1000;
  }

  function parseCSV(text, name) {
    var lines = text.split(/\r?\n/).filter(function (l) { return l.length > 0; });
    if (!lines.length) throw new Error("file has no rows");

    var header = lines[0].split(",").map(function (h) { return h.trim(); });
    var idx = {};
    header.forEach(function (h, i) { if (!(h in idx)) idx[h] = i; });

    var missing = REQUIRED.filter(function (c) { return !(c in idx); });
    if (missing.length) {
      throw new Error("missing required column" + (missing.length > 1 ? "s" : "") +
                      ": " + missing.join(", "));
    }

    var readings = [], device = "";
    for (var i = 1; i < lines.length; i++) {
      var f = lines[i].split(",");
      if (f.length < REQUIRED.length) continue;
      var t = parseTime(f[idx["time"]] || "");
      if (!isFinite(t)) continue;
      function num(c) { var v = parseFloat(f[idx[c]]); return isFinite(v) ? v : NaN; }
      var ax = num("AccX(g)"), ay = num("AccY(g)"), az = num("AccZ(g)");
      var gx = num("AsX(°/s)"), gy = num("AsY(°/s)"), gz = num("AsZ(°/s)");
      if (!isFinite(ax) || !isFinite(ay) || !isFinite(az) ||
          !isFinite(gx) || !isFinite(gy) || !isFinite(gz)) continue;
      if (!device && "DeviceName" in idx) device = (f[idx["DeviceName"]] || "").trim();
      readings.push({ t: t / 1000, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz });
    }
    if (!readings.length) throw new Error("file has a header but no readable data rows");

    var dur = readings[readings.length - 1].t - readings[0].t;
    return {
      name: name || "session",
      device: device || "unknown",
      readings: readings,
      duration: dur,
      sampleRateHz: dur > 0 ? readings.length / dur : 0
    };
  }

  /* ---------- detection ---------- */

  var DEFAULTS = {
    enterDPS: 60, exitDPS: 25, settleTime: 0.12,
    minDuration: 0.08, mergeGap: 0.10, maxDuration: 3.0,
    reversalAngleDeg: 120, minBurstShare: 0.4
  };

  function rateOf(r) { return Math.sqrt(r.gx * r.gx + r.gy * r.gy + r.gz * r.gz); }

  function netRotation(r, lo, hi) {
    var net = [0, 0, 0];
    for (var i = lo; i < hi && i + 1 < r.length; i++) {
      var dt = r[i + 1].t - r[i].t;
      net[0] += r[i].gx * dt; net[1] += r[i].gy * dt; net[2] += r[i].gz * dt;
    }
    return net;
  }

  function magnitude(v) {
    return Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  }

  function angleBetween(a, b) {
    var ma = magnitude(a), mb = magnitude(b);
    if (!(ma > 0) || !(mb > 0)) return 0;
    var c = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (ma * mb);
    return Math.acos(Math.max(-1, Math.min(1, c))) * 180 / Math.PI;
  }

  /* A back cast and the forward cast after it are the same movement in
     opposite directions, so their net rotation vectors point ~180° apart. At
     casting tempo the rod never settles between them and rate alone reports
     the pair as one stroke whose rotations cancel. See StrokeAnalysis.swift. */
  function splitAtReversals(span, r, rate, o) {
    var bursts = [], open = null, i;
    for (i = span[0]; i < span[1]; i++) {
      if (rate[i] >= o.enterDPS) {
        if (open === null) open = i;
      } else if (open !== null) {
        bursts.push([open, i]); open = null;
      }
    }
    if (open !== null) bursts.push([open, span[1]]);
    if (bursts.length < 2) return [span];

    var nets = bursts.map(function (b) { return netRotation(r, b[0], b[1]); });
    var largest = Math.max.apply(null, nets.map(magnitude));
    if (!(largest > 0)) return [span];

    var kept = [];
    for (i = 0; i < bursts.length; i++) {
      if (magnitude(nets[i]) >= o.minBurstShare * largest) kept.push([bursts[i], nets[i]]);
    }
    if (kept.length < 2) return [span];

    var cuts = [];
    for (i = 1; i < kept.length; i++) {
      if (angleBetween(kept[i - 1][1], kept[i][1]) < o.reversalAngleDeg) continue;
      var lo = kept[i - 1][0][1], hi = kept[i][0][0];
      if (hi <= lo) continue;
      var quietest = lo;
      for (var j = lo; j < hi; j++) if (rate[j] < rate[quietest]) quietest = j;
      cuts.push(quietest);
    }
    if (!cuts.length) return [span];

    var out = [], lower = span[0];
    cuts.forEach(function (cut) { out.push([lower, cut]); lower = cut; });
    out.push([lower, span[1]]);
    return out;
  }

  function splitIfTooLong(span, r, rate, opts, depth) {
    var dur = r[span[1] - 1].t - r[span[0]].t;
    if (!(dur > opts.maxDuration) || depth >= 6 || (span[1] - span[0]) <= 8) return [span];
    var n = span[1] - span[0];
    var margin = Math.max(2, Math.floor(n / 8));
    var lo = span[0] + margin, hi = span[1] - margin;
    if (lo >= hi) return [span];
    var cut = lo;
    for (var i = lo; i < hi; i++) if (rate[i] < rate[cut]) cut = i;
    return splitIfTooLong([span[0], cut], r, rate, opts, depth + 1)
      .concat(splitIfTooLong([cut, span[1]], r, rate, opts, depth + 1));
  }

  function detectStrokes(readings, options) {
    var o = Object.assign({}, DEFAULTS, options || {});
    if (readings.length <= 2) return [];
    var rate = readings.map(rateOf);

    var spans = [], start = null, quietSince = null;
    for (var i = 0; i < readings.length; i++) {
      if (rate[i] >= o.enterDPS) {
        if (start === null) start = i;
        quietSince = null;
      } else if (start !== null && rate[i] < o.exitDPS) {
        if (quietSince === null) quietSince = i;
        if (readings[i].t - readings[quietSince].t >= o.settleTime) {
          spans.push([start, quietSince]);
          start = null; quietSince = null;
        }
      } else {
        quietSince = null;
      }
    }
    if (start !== null) spans.push([start, readings.length]);

    var merged = [];
    spans.forEach(function (s) {
      var last = merged[merged.length - 1];
      if (last && readings[s[0]].t - readings[last[1] - 1].t < o.mergeGap) {
        merged[merged.length - 1] = [last[0], s[1]];
      } else merged.push(s);
    });

    var split = [];
    merged.forEach(function (s) {
      splitAtReversals(s, readings, rate, o).forEach(function (p) {
        split = split.concat(splitIfTooLong(p, readings, rate, o, 0));
      });
    });
    return split.filter(function (s) {
      return readings[s[1] - 1].t - readings[s[0]].t >= o.minDuration;
    });
  }

  /* ---------- per-stroke metrics ---------- */

  var PROFILE_POINTS = 16;

  /* A stopping point is only read from a genuinely still moment — see
     StrokeAnalyzer's own note. At casting tempo there often isn't one. */
  var STOP_STILL_MAX_RATE_DPS = 25;
  var STOP_STILL_MAX_ACC_DEV_G = 0.10;
  var STOP_STILL_SEARCH_SECONDS = 0.60;
  var STOP_STILL_WINDOW_SECONDS = 0.40;
  var STOP_STILL_MIN_SAMPLES = 8;
  var STOP_TRANSPORT_MAX_DEG = 90;
  /* The rod is moving again, so the quiet after this stroke is over. Without
     it the search runs into the next stroke and reports its far end as this
     one's stopping point. Matches the detector's enterDPS. */
  var STOP_SEARCH_ABORT_DPS = 60;

  function accMag(r) {
    return Math.sqrt(r.ax * r.ax + r.ay * r.ay + r.az * r.az);
  }

  /* Rotate v by angle radians about unit axis n (Rodrigues). */
  function rotated(v, n, angle) {
    var c = Math.cos(angle), s = Math.sin(angle);
    var cx = [n[1]*v[2] - n[2]*v[1], n[2]*v[0] - n[0]*v[2], n[0]*v[1] - n[1]*v[0]];
    var d = n[0]*v[0] + n[1]*v[1] + n[2]*v[2];
    return [v[0]*c + cx[0]*s + n[0]*d*(1 - c),
            v[1]*c + cx[1]*s + n[1]*d*(1 - c),
            v[2]*c + cx[2]*s + n[2]*d*(1 - c)];
  }

  /* Up, in the sensor's frame, at the moment the stroke stopped — or null.
     Gravity is read from the still moment after the stroke and carried back
     across the gyro to the stop, because the rod is not still at the stop and
     the hand keeps moving after it. StrokeAnalysis.swift has the measurements
     that forced both halves of that. */
  function stopUp(r, span, stopIndex) {
    if (!(span[1] <= r.length) || span[1] <= 0) return null;
    var end = r[span[1] - 1].t;

    function still(i) {
      return rateOf(r[i]) < STOP_STILL_MAX_RATE_DPS
        && Math.abs(accMag(r[i]) - 1) < STOP_STILL_MAX_ACC_DEV_G;
    }

    // A lone still-looking sample while the rod rings down is not a window.
    // Skip past a short run and keep looking rather than refusing outright.
    var windowStart = -1, sum = [0, 0, 0], n = 0, i = span[1];
    while (i < r.length && r[i].t - end <= STOP_STILL_SEARCH_SECONDS) {
      if (rateOf(r[i]) >= STOP_SEARCH_ABORT_DPS) break;
      if (!still(i)) { i++; continue; }
      var from = i, acc = [0, 0, 0], count = 0, j = i;
      while (j < r.length && r[j].t - r[from].t <= STOP_STILL_WINDOW_SECONDS && still(j)) {
        acc[0] += r[j].ax; acc[1] += r[j].ay; acc[2] += r[j].az;
        count++; j++;
      }
      if (count >= STOP_STILL_MIN_SAMPLES) { windowStart = from; sum = acc; n = count; break; }
      i = j + 1;
    }
    if (n < STOP_STILL_MIN_SAMPLES) return null;

    var m = Math.sqrt(sum[0]*sum[0] + sum[1]*sum[1] + sum[2]*sum[2]);
    if (!(m > 0)) return null;
    var up = [sum[0]/m, sum[1]/m, sum[2]/m];

    var DEG = Math.PI / 180, turned = 0;
    for (var j = windowStart - 1; j >= stopIndex; j--) {
      var dt = r[j + 1].t - r[j].t;
      var w = [r[j].gx*DEG, r[j].gy*DEG, r[j].gz*DEG];
      var mag = Math.sqrt(w[0]*w[0] + w[1]*w[1] + w[2]*w[2]);
      var ang = mag*dt;
      if (ang > 1e-12) {
        up = rotated(up, [w[0]/mag, w[1]/mag, w[2]/mag], ang);
        turned += ang/DEG;
      }
    }
    if (turned > STOP_TRANSPORT_MAX_DEG) return null;
    return { up: up, samples: n };
  }

  function strokeMetrics(readings, span, index, sessionStart) {
    var n = span[1] - span[0];
    if (n < 3) return null;
    var r = readings.slice(span[0], span[1]);
    var t = r.map(function (x) { return x.t - r[0].t; });
    var duration = t[n - 1];
    if (!(duration > 0)) return null;

    var rate = r.map(rateOf);

    var net = [0, 0, 0], path = 0;
    for (var i = 0; i < n - 1; i++) {
      var dt = t[i + 1] - t[i];
      net[0] += r[i].gx * dt; net[1] += r[i].gy * dt; net[2] += r[i].gz * dt;
      path += rate[i] * dt;
    }
    var arc = Math.sqrt(net[0] * net[0] + net[1] * net[1] + net[2] * net[2]);
    var dom = 0;
    for (var d = 1; d < 3; d++) if (Math.abs(net[d]) > Math.abs(net[dom])) dom = d;
    var planarity = arc > 0 ? Math.abs(net[dom]) / arc * 100 : 0;

    // Turning in the stroke's own plane, and turning out of it — measured
    // against the axis the stroke actually turned about, so remounting the
    // sensor doesn't change it.
    var alongPath = 0, perpPath = 0;
    if (arc > 0) {
      var n0 = [net[0] / arc, net[1] / arc, net[2] / arc];
      for (var q = 0; q < n - 1; q++) {
        var dtq = t[q + 1] - t[q];
        var wq = [r[q].gx, r[q].gy, r[q].gz];
        var along = wq[0]*n0[0] + wq[1]*n0[1] + wq[2]*n0[2];
        var perp = [wq[0] - along*n0[0], wq[1] - along*n0[1], wq[2] - along*n0[2]];
        alongPath += Math.abs(along) * dtq;
        perpPath += Math.sqrt(perp[0]*perp[0] + perp[1]*perp[1] + perp[2]*perp[2]) * dtq;
      }
    }
    var inPlane = alongPath + perpPath > 0 ? alongPath / (alongPath + perpPath) * 100 : 0;

    var peakIdx = 0;
    for (var k = 1; k < n; k++) if (rate[k] > rate[peakIdx]) peakIdx = k;
    var peakRate = rate[peakIdx];

    function alpha(i) {
      var a = Math.max(0, i - 2), b = Math.min(n - 1, i + 2);
      var dt2 = t[b] - t[a];
      return dt2 > 0 ? (rate[b] - rate[a]) / dt2 : 0;
    }

    var peakAccel = 0;
    for (var g2 = 0; g2 < peakIdx; g2++) { var a3 = alpha(g2); if (a3 > peakAccel) peakAccel = a3; }

    var rising = 0, driveTime = 0;
    for (var h2 = 0; h2 < peakIdx; h2++) {
      var dth = t[h2 + 1] - t[h2];
      driveTime += dth;
      if (alpha(h2) > 0) rising += dth;
    }
    var driveSmooth = driveTime > 0 ? rising / driveTime * 100 : 0;

    var peakDecel = 0;
    if (peakIdx < n - 1) {
      for (var j = peakIdx; j < n; j++) { var a2 = alpha(j); if (a2 < peakDecel) peakDecel = a2; }
    }

    var stopEnd = n - 1, floorRate = peakRate * 0.2;
    for (var s2 = peakIdx; s2 < n; s2++) if (rate[s2] <= floorRate) { stopEnd = s2; break; }

    var peakAcc = 0;
    r.forEach(function (x) {
      var m = accMag(x);
      if (m > peakAcc) peakAcc = m;
    });

    // The rate curve on a common grid, scaled by its own peak: what is left
    // after size and length are divided out is shape.
    var profile = new Array(PROFILE_POINTS);
    for (var p2 = 0; p2 < PROFILE_POINTS; p2++) profile[p2] = 0;
    if (peakRate > 0) {
      var jj = 0;
      for (var kk = 0; kk < PROFILE_POINTS; kk++) {
        var want = duration * kk / (PROFILE_POINTS - 1);
        while (jj + 1 < n - 1 && t[jj + 1] < want) jj++;
        var dtp = t[jj + 1] - t[jj];
        var frac = dtp > 0 ? Math.max(0, Math.min(1, (want - t[jj]) / dtp)) : 0;
        profile[kk] = (rate[jj] + (rate[jj + 1] - rate[jj]) * frac) / peakRate;
      }
    }

    // The stop itself: the slowest moment after the peak. Distinct from
    // stopEnd, which is where the rate first falls to a fifth of peak.
    var stopIdx = peakIdx;
    for (var v2 = peakIdx; v2 < n; v2++) if (rate[v2] < rate[stopIdx]) stopIdx = v2;
    var stop = stopUp(readings, span, span[0] + stopIdx);

    var stopPhase = Math.max(t[stopEnd] - t[peakIdx], 0);
    return {
      index: index,
      startTime: r[0].t - sessionStart,
      duration: duration,
      samples: n,
      arcDeg: arc,
      netRotationDeg: net.slice(),
      pathDeg: path,
      planarityPct: planarity,
      dominantAxis: ["X", "Y", "Z"][dom],
      offPlaneDeg: perpPath,
      inPlanePct: inPlane,
      peakRateDPS: peakRate,
      peakRateAtPct: t[peakIdx] / duration * 100,
      accelPhase: t[peakIdx],
      stopPhase: stopPhase,
      peakAccelDPS2: peakAccel,
      peakDecelDPS2: Math.abs(peakDecel),
      driveSmoothPct: driveSmooth,
      stopSharePct: duration > 0 ? stopPhase / duration * 100 : 0,
      rateProfile: profile,
      stopUp: stop ? stop.up : null,
      stopStillSamples: stop ? stop.samples : 0,
      peakAccG: peakAcc,
      tempo: duration > 0 ? arc / duration : 0,
      span: span
    };
  }

  function analyze(session, options) {
    var readings = session.readings;
    if (!readings.length) return [];
    var start = readings[0].t;
    return detectStrokes(readings, options)
      .map(function (span, i) { return strokeMetrics(readings, span, i + 1, start); })
      .filter(Boolean);
  }

  /* ---------- consistency ---------- */

  function spread(name, unit, values) {
    var n = values.length;
    var mean = n ? values.reduce(function (a, b) { return a + b; }, 0) / n : 0;
    var sd = 0;
    if (n > 1) {
      sd = Math.sqrt(values.reduce(function (a, v) { return a + (v - mean) * (v - mean); }, 0) / (n - 1));
    }
    var outliers = [];
    if (n > 2 && sd > 0) {
      values.forEach(function (v, i) { if (Math.abs(v - mean) > 2 * sd) outliers.push(i); });
    }
    return {
      name: name, unit: unit, values: values, mean: mean, sd: sd,
      cvPct: mean === 0 ? 0 : Math.abs(sd / mean) * 100,
      min: n ? Math.min.apply(null, values) : 0,
      max: n ? Math.max.apply(null, values) : 0,
      outliers: outliers
    };
  }

  function spreads(strokes) {
    function col(f) { return strokes.map(f); }
    return [
      spread("Arc swept", "°", col(function (s) { return s.arcDeg; })),
      spread("Duration", "s", col(function (s) { return s.duration; })),
      spread("Peak rate", "°/s", col(function (s) { return s.peakRateDPS; })),
      spread("Peak at", "% of stroke", col(function (s) { return s.peakRateAtPct; })),
      spread("Drive accel", "°/s²", col(function (s) { return s.peakAccelDPS2; })),
      spread("Drive smooth", "% of drive", col(function (s) { return s.driveSmoothPct; })),
      spread("Stop decel", "°/s²", col(function (s) { return s.peakDecelDPS2; })),
      spread("Stop share", "% of stroke", col(function (s) { return s.stopSharePct; })),
      spread("Off-plane", "°", col(function (s) { return s.offPlaneDeg; })),
      spread("Planarity", "%", col(function (s) { return s.planarityPct; })),
      spread("Peak accel", "g", col(function (s) { return s.peakAccG; }))
    ];
  }

  var CORE = ["Arc swept", "Duration", "Peak rate", "Drive accel", "Stop decel"];
  function repeatabilityCV(strokes) {
    if (strokes.length <= 2) return null;
    var core = spreads(strokes).filter(function (s) { return CORE.indexOf(s.name) >= 0; });
    return core.reduce(function (a, s) { return a + s.cvPct; }, 0) / core.length;
  }

  function verdict(cv) {
    if (cv < 10) return "very consistent";
    if (cv < 20) return "consistent";
    if (cv < 35) return "variable";
    return "highly variable";
  }

  /* ---------- repeatability of shape and position ---------- */

  function unitVec(v) {
    if (!v) return null;
    var m = Math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    if (!(m > 1e-12) || !isFinite(m)) return null;
    return [v[0]/m, v[1]/m, v[2]/m];
  }
  function dot3(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
  function angleDeg3(a, b) {
    return Math.acos(Math.max(-1, Math.min(1, dot3(a, b)))) * 180 / Math.PI;
  }

  /* The strokes big enough to be casts — half the median arc of the largest
     third, PLAN.md §6's relative rule. A lift travels in its own plane, and
     counting it reads as a caster whose plane wanders. */
  function casts(strokes) {
    if (strokes.length < 3) return strokes;
    var sorted = strokes.map(function (s) { return s.arcDeg; })
      .sort(function (a, b) { return b - a; });
    var top = sorted.slice(0, Math.max(1, Math.floor(sorted.length / 3)));
    var median = top[Math.floor(top.length / 2)];
    if (!(median > 0)) return strokes;
    return strokes.filter(function (s) { return s.arcDeg >= median / 2; });
  }

  /* The session's casting axis, and which way each stroke turned about it.
     Back casts and forward casts are antiparallel, so the sign is folded before
     averaging or the session cancels to nothing. */
  function castingFrame(strokes) {
    if (!strokes.length) return null;
    var anchorIdx = 0;
    for (var i = 1; i < strokes.length; i++) {
      if (strokes[i].arcDeg > strokes[anchorIdx].arcDeg) anchorIdx = i;
    }
    var anchor = unitVec(strokes[anchorIdx].netRotationDeg);
    if (!anchor) return null;

    var sum = [0, 0, 0];
    strokes.forEach(function (m) {
      var v = m.netRotationDeg, s = dot3(v, anchor) >= 0 ? 1 : -1;
      sum[0] += s*v[0]; sum[1] += s*v[1]; sum[2] += s*v[2];
    });
    var axis = unitVec(sum);
    if (!axis) return null;
    var flip = dot3(anchor, axis) >= 0 ? 1 : -1;
    var a = [axis[0]*flip, axis[1]*flip, axis[2]*flip];
    return {
      axis: a,
      signs: strokes.map(function (m) { return dot3(m.netRotationDeg, a) >= 0 ? 1 : -1; })
    };
  }

  function angularSpread(name, vectors, strokeIndices, weights, foldSign) {
    var units = vectors.map(unitVec);
    var present = [];
    units.forEach(function (u, i) { if (u) present.push(i); });
    if (present.length < 2) return null;

    var anchorAt = present[0];
    present.forEach(function (i) { if (weights[i] > weights[anchorAt]) anchorAt = i; });
    var anchor = units[anchorAt];

    var sum = [0, 0, 0];
    present.forEach(function (i) {
      var u = units[i], s = foldSign ? (dot3(u, anchor) >= 0 ? 1 : -1) : 1, w = weights[i];
      sum[0] += s*w*u[0]; sum[1] += s*w*u[1]; sum[2] += s*w*u[2];
    });
    var mean = unitVec(sum);
    if (!mean) return null;

    var devs = units.map(function () { return null; }), values = [];
    present.forEach(function (i) {
      var a = angleDeg3(units[i], mean);
      if (foldSign) a = Math.min(a, 180 - a);   // a plane has no front and back
      devs[i] = a;
      values.push(a);
    });

    var nv = values.length;
    var meanDev = values.reduce(function (a, b) { return a + b; }, 0) / nv;
    // About zero, not about the mean deviation: every degree off the mean
    // direction is error, whether or not the others are off by as much.
    var sd = Math.sqrt(values.reduce(function (a, b) { return a + b*b; }, 0) / nv);
    var worst = present[0];
    present.forEach(function (i) { if (devs[i] > devs[worst]) worst = i; });

    return {
      name: name, count: nv, missing: units.length - nv,
      meanDeg: meanDev, sdDeg: sd, maxDeg: Math.max.apply(null, values),
      worstStroke: strokeIndices[worst], deviationsDeg: devs
    };
  }

  function planeSpread(strokes) {
    return angularSpread("Casting plane",
      strokes.map(function (s) { return s.arcDeg > 0 ? s.netRotationDeg : null; }),
      strokes.map(function (s) { return s.index; }),
      strokes.map(function (s) { return s.arcDeg; }),
      true);
  }

  function stopSpread(strokes, name) {
    return angularSpread(name,
      strokes.map(function (s) { return s.stopUp; }),
      strokes.map(function (s) { return s.index; }),
      strokes.map(function () { return 1; }),
      false);
  }

  function profileAgreement(strokes, name) {
    var usable = strokes.filter(function (s) {
      return s.rateProfile && s.rateProfile.length === PROFILE_POINTS && s.peakRateDPS > 0;
    });
    if (usable.length < 2) return null;

    var mean = new Array(PROFILE_POINTS), k;
    for (k = 0; k < PROFILE_POINTS; k++) mean[k] = 0;
    usable.forEach(function (m) {
      for (k = 0; k < PROFILE_POINTS; k++) mean[k] += m.rateProfile[k];
    });
    for (k = 0; k < PROFILE_POINTS; k++) mean[k] /= usable.length;

    var devs = usable.map(function (m) {
      var acc = 0;
      for (var i = 0; i < PROFILE_POINTS; i++) {
        var d = m.rateProfile[i] - mean[i];
        acc += d*d;
      }
      return Math.sqrt(acc / PROFILE_POINTS) * 100;
    });
    var worst = 0;
    devs.forEach(function (d, i) { if (d > devs[worst]) worst = i; });
    var meanDev = devs.reduce(function (a, b) { return a + b; }, 0) / devs.length;

    return {
      name: name, count: usable.length,
      meanDeviationPct: meanDev,
      maxDeviationPct: Math.max.apply(null, devs),
      agreementPct: Math.max(0, 100 - meanDev),
      worstStroke: usable[worst].index,
      deviationsPct: devs, meanProfile: mean
    };
  }

  var DIRECTION_NAMES = ["one way", "the other way"];

  /* Where the rod stops, how it is driven there, and the plane it travels in.
     Stops and drive shape are split by direction: a back cast and a forward
     cast stop in two different places and are driven two different ways, so
     measured together their spread is the gap between the groups and says
     nothing about how repeatable either one is. */
  function repeatability(all) {
    var s = casts(all);
    var unmeasured = s.filter(function (m) { return !m.stopUp; }).length;
    var base = {
      plane: planeSpread(s), stops: [], drive: [],
      castCount: s.length, setAside: all.length - s.length,
      stopsUnmeasured: unmeasured
    };
    var frame = s.length >= 2 ? castingFrame(s) : null;
    if (!frame) return base;

    [1, -1].forEach(function (sign, k) {
      var group = s.filter(function (m, i) { return frame.signs[i] === sign; });
      if (group.length < 2) return;
      var sp = stopSpread(group, "Stops, " + DIRECTION_NAMES[k]);
      if (sp) base.stops.push(sp);
      var pa = profileAgreement(group, "Drive shape, " + DIRECTION_NAMES[k]);
      if (pa) base.drive.push(pa);
    });
    return base;
  }

  /* Where the corpus falls: plane spread runs 4.8-20.2° across its fourteen
     usable sessions and stopping points 3.6-15.4°. One scale for both, because
     both are degrees away from a mean direction. */
  function angularVerdict(sdDeg) {
    if (sdDeg < 5) return "very consistent";
    if (sdDeg < 10) return "consistent";
    if (sdDeg < 15) return "variable";
    return "highly variable";
  }

  root.CastrAnalysis = {
    parseCSV: parseCSV,
    detectStrokes: detectStrokes,
    strokeMetrics: strokeMetrics,
    analyze: analyze,
    spreads: spreads,
    repeatabilityCV: repeatabilityCV,
    verdict: verdict,
    casts: casts,
    castingFrame: castingFrame,
    planeSpread: planeSpread,
    stopSpread: stopSpread,
    profileAgreement: profileAgreement,
    repeatability: repeatability,
    angularVerdict: angularVerdict,
    rateOf: rateOf,
    PROFILE_POINTS: PROFILE_POINTS,
    DEFAULTS: DEFAULTS
  };
})(typeof globalThis !== "undefined" ? globalThis : this);

if (typeof module !== "undefined" && module.exports) module.exports = globalThis.CastrAnalysis;
