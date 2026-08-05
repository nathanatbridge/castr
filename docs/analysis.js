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

    var peakIdx = 0;
    for (var k = 1; k < n; k++) if (rate[k] > rate[peakIdx]) peakIdx = k;
    var peakRate = rate[peakIdx];

    function alpha(i) {
      var a = Math.max(0, i - 2), b = Math.min(n - 1, i + 2);
      var dt2 = t[b] - t[a];
      return dt2 > 0 ? (rate[b] - rate[a]) / dt2 : 0;
    }
    var peakDecel = 0;
    if (peakIdx < n - 1) {
      for (var j = peakIdx; j < n; j++) { var a2 = alpha(j); if (a2 < peakDecel) peakDecel = a2; }
    }

    var stopEnd = n - 1, floorRate = peakRate * 0.2;
    for (var s2 = peakIdx; s2 < n; s2++) if (rate[s2] <= floorRate) { stopEnd = s2; break; }

    var peakAcc = 0;
    r.forEach(function (x) {
      var m = Math.sqrt(x.ax * x.ax + x.ay * x.ay + x.az * x.az);
      if (m > peakAcc) peakAcc = m;
    });

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
      peakRateDPS: peakRate,
      peakRateAtPct: t[peakIdx] / duration * 100,
      accelPhase: t[peakIdx],
      stopPhase: stopPhase,
      peakDecelDPS2: Math.abs(peakDecel),
      stopSharePct: duration > 0 ? stopPhase / duration * 100 : 0,
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
      spread("Stop decel", "°/s²", col(function (s) { return s.peakDecelDPS2; })),
      spread("Stop share", "% of stroke", col(function (s) { return s.stopSharePct; })),
      spread("Planarity", "%", col(function (s) { return s.planarityPct; })),
      spread("Peak accel", "g", col(function (s) { return s.peakAccG; }))
    ];
  }

  var CORE = ["Arc swept", "Duration", "Peak rate", "Stop decel"];
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

  root.CastrAnalysis = {
    parseCSV: parseCSV,
    detectStrokes: detectStrokes,
    strokeMetrics: strokeMetrics,
    analyze: analyze,
    spreads: spreads,
    repeatabilityCV: repeatabilityCV,
    verdict: verdict,
    rateOf: rateOf,
    DEFAULTS: DEFAULTS
  };
})(typeof globalThis !== "undefined" ? globalThis : this);

if (typeof module !== "undefined" && module.exports) module.exports = globalThis.CastrAnalysis;
