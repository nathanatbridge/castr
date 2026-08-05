/* Castr swing-path reconstruction — browser port of tools/reconstruct.py.
 *
 * Position is NOT double-integrated from acceleration. That drifts without
 * bound and would be fiction within a second. The sensor is treated as a point
 * on a rigid arm turning about a pivot, so position follows from orientation
 * (well conditioned, integrated from the gyro) times a constant lever arm. The
 * arm is measured from the acceleration, not assumed.
 *
 * What differs from the Python tool: that one finds its own "events" by
 * thresholding acceleration deviation, which merges a whole false-casting
 * sequence into one blob. This works from the strokes analysis.js already
 * detected, and reconstructs a whole burst at once so the back-and-forward
 * alternation is visible as one continuous path.
 */
(function (root) {
  "use strict";

  var G = 9.80665;
  var DEG = Math.PI / 180;

  /* ---------- quaternions (w, x, y, z) ---------- */

  function qmul(a, b) {
    return [a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
            a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
            a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
            a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0]];
  }
  function qnorm(q) {
    var n = Math.sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
    return [q[0]/n, q[1]/n, q[2]/n, q[3]/n];
  }
  function qconj(q) { return [q[0], -q[1], -q[2], -q[3]]; }

  /* Rotate v by q (body -> world). */
  function qrot(q, v) {
    var w = q[0], x = q[1], y = q[2], z = q[3];
    var tx = 2*(y*v[2] - z*v[1]), ty = 2*(z*v[0] - x*v[2]), tz = 2*(x*v[1] - y*v[0]);
    return [v[0] + w*tx + (y*tz - z*ty),
            v[1] + w*ty + (z*tx - x*tz),
            v[2] + w*tz + (x*ty - y*tx)];
  }

  function qAxisAngle(axis, ang) {
    var n = Math.sqrt(axis[0]*axis[0] + axis[1]*axis[1] + axis[2]*axis[2]);
    if (n < 1e-12) return [1, 0, 0, 0];
    var s = Math.sin(ang/2)/n;
    return [Math.cos(ang/2), axis[0]*s, axis[1]*s, axis[2]*s];
  }

  /* Shortest-arc rotation taking unit vector a onto unit vector b. */
  function qAlign(a, b) {
    var d = a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
    if (d > 0.999999) return [1, 0, 0, 0];
    var cx = [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]];
    if (d < -0.999999) {
      var ax = Math.abs(a[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0];
      cx = [a[1]*ax[2] - a[2]*ax[1], a[2]*ax[0] - a[0]*ax[2], a[0]*ax[1] - a[1]*ax[0]];
      return qAxisAngle(cx, Math.PI);
    }
    return qnorm([1 + d, cx[0], cx[1], cx[2]]);
  }

  /* Gauss-Jordan with partial pivoting. Null when singular. */
  function solve3(A, b) {
    var M = [A[0].concat([b[0]]), A[1].concat([b[1]]), A[2].concat([b[2]])], c, r, k, p, f;
    for (c = 0; c < 3; c++) {
      p = c;
      for (r = c + 1; r < 3; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
      var tmp = M[c]; M[c] = M[p]; M[p] = tmp;
      if (Math.abs(M[c][c]) < 1e-14) return null;
      for (r = 0; r < 3; r++) {
        if (r === c) continue;
        f = M[r][c]/M[c][c];
        for (k = c; k < 4; k++) M[r][k] -= f*M[c][k];
      }
    }
    return [M[0][3]/M[0][0], M[1][3]/M[1][1], M[2][3]/M[2][2]];
  }

  /* ---------- helpers over the readings ---------- */

  function rateRad(r) {
    return Math.sqrt(r.gx*r.gx + r.gy*r.gy + r.gz*r.gz) * DEG;
  }
  function accMag(r) {
    return Math.sqrt(r.ax*r.ax + r.ay*r.ay + r.az*r.az);
  }

  /* Gyro bias, measured over every still sample in the session. The WT901BLE's
     bias is small (0.0014 °/s on cast2) but it integrates, so it is removed
     rather than ignored. */
  function gyroBias(readings) {
    var sx = 0, sy = 0, sz = 0, n = 0;
    for (var i = 0; i < readings.length; i++) {
      var r = readings[i];
      if (rateRad(r) < 3*DEG && Math.abs(accMag(r) - 1) < 0.05) {
        sx += r.gx; sy += r.gy; sz += r.gz; n++;
      }
    }
    return n ? { bias: [sx/n, sy/n, sz/n], samples: n } : { bias: [0, 0, 0], samples: 0 };
  }

  /* Strokes separated by less than gapSeconds belong to the same burst. A
     burst is one continuous sequence of casting — it is what a delivery tap
     should bind to, and it is the unit worth drawing as a single path. */
  function groupBursts(readings, spans, gapSeconds) {
    var out = [], cur = [];
    for (var i = 0; i < spans.length; i++) {
      if (cur.length) {
        var prevEnd = readings[spans[cur[cur.length - 1]][1] - 1].t;
        if (readings[spans[i][0]].t - prevEnd > gapSeconds) { out.push(cur); cur = []; }
      }
      cur.push(i);
    }
    if (cur.length) out.push(cur);
    return out;
  }

  /* The quietest run of samples before `from`, used as the gravity reference.
     Back-to-back strokes have no rest between them, so the reference has to
     come from before the whole burst — and when there is none, that is worth
     reporting rather than papering over. PLAN.md makes the same point about
     elevation: no still window means no estimate. */
  function gravityReference(readings, from, lookBackSeconds) {
    var startT = readings[from].t - lookBackSeconds, i, best = null, run = [];
    for (i = from - 1; i >= 0 && readings[i].t >= startT; i--) {
      if (rateRad(readings[i]) < 5*DEG && Math.abs(accMag(readings[i]) - 1) < 0.08) {
        run.push(i);
      } else if (run.length) {
        if (!best || run.length > best.length) best = run;
        run = [];
      }
    }
    if (run.length && (!best || run.length > best.length)) best = run;
    if (!best || best.length < 10) return null;
    var gx = 0, gy = 0, gz = 0;
    for (i = 0; i < best.length; i++) {
      gx += readings[best[i]].ax; gy += readings[best[i]].ay; gz += readings[best[i]].az;
    }
    var n = Math.sqrt(gx*gx + gy*gy + gz*gz);
    if (!(n > 0)) return null;
    return { g: [gx/n, gy/n, gz/n], samples: best.length };
  }

  /* ---------- the reconstruction ---------- */

  function reconstructBurst(readings, spans, strokeIdx, bias, opts) {
    var i0 = spans[strokeIdx[0]][0];
    var i1 = spans[strokeIdx[strokeIdx.length - 1]][1] - 1;

    // Start a little before the first stroke so the path opens from rest where
    // the data allows it.
    var pad = opts.padSeconds;
    var a = i0;
    while (a > 0 && readings[i0].t - readings[a].t < pad) a--;
    var b = i1;
    while (b < readings.length - 1 && readings[b].t - readings[i1].t < pad) b++;

    var ref = gravityReference(readings, i0, opts.lookBackSeconds);
    var grounded = !!ref;
    if (!ref) {
      // No still window: fall back to the quietest single sample so something
      // is drawn, but say the orientation is not anchored.
      var qi = a, qr = Infinity;
      for (var i = a; i <= b; i++) {
        var rr = rateRad(readings[i]);
        if (rr < qr) { qr = rr; qi = i; }
      }
      var m = accMag(readings[qi]) || 1;
      ref = { g: [readings[qi].ax/m, readings[qi].ay/m, readings[qi].az/m], samples: 1 };
    }

    var q = qAlign(ref.g, [0, 0, 1]);

    // Integrate orientation forward, collecting dynamic acceleration and the
    // angular velocity/acceleration the lever-arm fit needs.
    var quats = [], dyn = [], w = [], w2 = [], n = b - a + 1, k;
    for (k = 0; k < n; k++) {
      var r = readings[a + k];
      var wv = [(r.gx - bias[0])*DEG, (r.gy - bias[1])*DEG, (r.gz - bias[2])*DEG];
      var mag = Math.sqrt(wv[0]*wv[0] + wv[1]*wv[1] + wv[2]*wv[2]);
      quats.push(q);
      var gb = qrot(qconj(q), [0, 0, 1]);           // gravity, in the body frame
      dyn.push([(r.ax - gb[0])*G, (r.ay - gb[1])*G, (r.az - gb[2])*G]);
      w.push(wv);
      w2.push(mag*mag);
      if (a + k < b) {
        var dt = readings[a + k + 1].t - r.t;
        var ang = mag*dt;
        if (ang > 1e-12) q = qnorm(qmul(q, qAxisAngle(wv, ang)));
      }
    }

    // Angular acceleration, centrally differenced over a short window — a raw
    // sample-to-sample difference at 200 Hz is mostly quantisation.
    var alpha = [];
    for (k = 0; k < n; k++) {
      var k0 = Math.max(0, k - 2), k1 = Math.min(n - 1, k + 2);
      var dta = readings[a + k1].t - readings[a + k0].t;
      alpha.push(dta > 0
        ? [(w[k1][0]-w[k0][0])/dta, (w[k1][1]-w[k0][1])/dta, (w[k1][2]-w[k0][2])/dta]
        : [0, 0, 0]);
    }

    // Lever arm from the full rigid-body model:
    //   a_dyn = w x (w x r) + alpha x r = (w w^T - |w|^2 I) r + [alpha]_x r
    // Both terms are linear in r, so it is one linear least-squares solve.
    // Fitting the centripetal term alone leaves the tangential term in the
    // residual and biases the radius.
    function design(k) {
      var wk = w[k], al = alpha[k], M = [], i, j;
      for (i = 0; i < 3; i++) {
        M.push([]);
        for (j = 0; j < 3; j++) M[i].push(wk[i]*wk[j] - (i === j ? w2[k] : 0));
      }
      M[0][1] += -al[2]; M[0][2] +=  al[1];
      M[1][0] +=  al[2]; M[1][2] += -al[0];
      M[2][0] += -al[1]; M[2][1] +=  al[0];
      return M;
    }

    var ATA = [[0,0,0],[0,0,0],[0,0,0]], ATb = [0,0,0], used = 0, i2, j2, m2;
    for (k = 0; k < n; k++) {
      if (w2[k] < opts.minOmega2) continue;      // too slow for the dynamics to show
      used++;
      var Mk = design(k);
      for (i2 = 0; i2 < 3; i2++) {
        for (j2 = 0; j2 < 3; j2++) {
          for (m2 = 0; m2 < 3; m2++) ATA[i2][j2] += Mk[m2][i2]*Mk[m2][j2];
        }
        for (m2 = 0; m2 < 3; m2++) ATb[i2] += Mk[m2][i2]*dyn[k][m2];
      }
    }
    // The arm is only observable perpendicular to the rotation axis. Both
    // w x (w x r) and alpha x r annihilate the component of r along w, so when
    // a swing holds one axis — which is exactly what a good cast does — that
    // component leaves no trace in the acceleration at all. Left alone the
    // solve fills it with whatever fits the noise: on the fixture it returned
    // 59.9 cm for an arm whose observable part is 27.8 cm, while still fitting
    // the data to a residual of 0.009.
    //
    // A ridge term takes the minimum-norm solution instead, which drops the
    // unobservable component rather than inventing it. What comes back is the
    // swing radius: the part that actually determines the path.
    var trace = ATA[0][0] + ATA[1][1] + ATA[2][2];
    var lambda = trace * opts.ridge / 3;
    for (i2 = 0; i2 < 3; i2++) ATA[i2][i2] += lambda;

    var rBody = used >= 25 ? solve3(ATA, ATb) : null;
    if (!rBody) return { ok: false, strokes: strokeIdx, reason: used >= 25 ? "singular" : "too slow" };

    // A least-squares solve always returns *an* answer. When the motion isn't
    // rotation about a fixed arm the answer is meaningless, and drawing it
    // would present invention as measurement. Reject the implausible ones:
    // nobody's wrist is 125 m from the sensor.
    var armM = Math.sqrt(rBody[0]*rBody[0] + rBody[1]*rBody[1] + rBody[2]*rBody[2]);
    if (!(armM >= opts.minArmM && armM <= opts.maxArmM)) {
      return { ok: false, strokes: strokeIdx, reason: "implausible arm",
               armCm: armM*100 };
    }

    // Residual: the share of dynamic acceleration a rigid arm fails to explain.
    var num = 0, den = 0;
    for (k = 0; k < n; k++) {
      if (w2[k] < opts.minOmega2) continue;
      var Mk2 = design(k);
      for (i2 = 0; i2 < 3; i2++) {
        var pred = Mk2[i2][0]*rBody[0] + Mk2[i2][1]*rBody[1] + Mk2[i2][2]*rBody[2];
        num += (dyn[k][i2] - pred)*(dyn[k][i2] - pred);
        den += dyn[k][i2]*dyn[k][i2];
      }
    }
    var residual = den > 0 ? Math.sqrt(num/den) : null;

    // Residual near 1 means the rigid-arm model explains essentially none of
    // the measured acceleration, so the path it implies is not a measurement
    // of anything. Report the figure with the rejection — it is the evidence.
    if (residual !== null && residual > opts.maxResidual) {
      return { ok: false, strokes: strokeIdx, reason: "model does not fit",
               armCm: armM*100, residual: residual };
    }

    // Trajectory: pivot at the origin, sensor at R(t)·r_body.
    var raw = [];
    for (k = 0; k < n; k++) raw.push(qrot(quats[k], rBody));

    // Gravity fixes which way is up but leaves the heading free. Rotate about
    // the vertical so the swing's dominant horizontal direction becomes +X:
    // the side view (XZ) then carries the arc and the overhead view (XY) shows
    // departure from the plane, rather than both being arbitrary slices.
    var mx = 0, my = 0;
    for (k = 0; k < n; k++) { mx += raw[k][0]; my += raw[k][1]; }
    mx /= n; my /= n;
    var sxx = 0, syy = 0, sxy = 0;
    for (k = 0; k < n; k++) {
      sxx += (raw[k][0]-mx)*(raw[k][0]-mx);
      syy += (raw[k][1]-my)*(raw[k][1]-my);
      sxy += (raw[k][0]-mx)*(raw[k][1]-my);
    }
    var theta = 0.5*Math.atan2(2*sxy, sxx - syy);
    var ct = Math.cos(-theta), st = Math.sin(-theta);
    var pts = [];
    for (k = 0; k < n; k++) {
      pts.push([raw[k][0]*ct - raw[k][1]*st, raw[k][0]*st + raw[k][1]*ct, raw[k][2]]);
    }

    // Which end of that axis is "forward" is not in the data. Gravity fixes
    // which way is up but leaves the heading free, so the swing axis comes out
    // of the principal-axis fit without a sign — this is the sign anchor
    // PLAN.md Stage 2 is still open on.
    //
    // The convention used here is the one that plan proposes: the pickup goes
    // back, so the first real stroke of a burst sweeps away from forward. It is
    // an assumption, not a measurement, and the view offers a flip for when it
    // is wrong. Strokes that barely move along the axis can't say anything
    // about direction, so the first one that actually travels is used.
    var extentRaw = 0, xlo = Infinity, xhi = -Infinity;
    for (k = 0; k < n; k++) {
      if (pts[k][0] < xlo) xlo = pts[k][0];
      if (pts[k][0] > xhi) xhi = pts[k][0];
    }
    extentRaw = xhi - xlo;

    var anchor = null;
    for (var si = 0; si < strokeIdx.length; si++) {
      var f0 = spans[strokeIdx[si]][0] - a, t0 = spans[strokeIdx[si]][1] - 1 - a;
      var d0 = pts[t0][0] - pts[f0][0];
      if (Math.abs(d0) >= 0.25*extentRaw) { anchor = d0; break; }
    }
    if (anchor === null) anchor = pts[n - 1][0] - pts[0][0];

    // The first travelling stroke goes back, so it should sweep toward -X.
    if (anchor > 0) {
      for (k = 0; k < n; k++) { pts[k][0] = -pts[k][0]; pts[k][1] = -pts[k][1]; }
    }

    var xs = pts.map(function (p) { return p[0]; });
    var ys = pts.map(function (p) { return p[1]; });
    var extent = (Math.max.apply(null, xs) - Math.min.apply(null, xs))*100;
    var outOfPlane = (Math.max.apply(null, ys) - Math.min.apply(null, ys))*100;

    // Which way each stroke turned. This is the sign of its net rotation about
    // the burst's own axis, not the direction the path swept: a sequence that
    // keeps turning the same way passes right around the pivot, and the sweep
    // flips sign each time it goes over the top while the rotation never
    // reverses. The fixture does exactly that for its first five strokes.
    //
    // The net rotation integral is the one StrokeAnalysis calls netRotationDeg.
    function netRot(lo, hi) {
      var v = [0, 0, 0];
      for (var i = lo; i < hi && i + 1 < readings.length; i++) {
        var dt = readings[i + 1].t - readings[i].t;
        v[0] += readings[i].gx*dt; v[1] += readings[i].gy*dt; v[2] += readings[i].gz*dt;
      }
      return v;
    }
    var nets = strokeIdx.map(function (si) { return netRot(spans[si][0], spans[si][1]); });

    // Burst axis: every stroke's rotation summed with its sign aligned to the
    // first, so back casts and forward casts reinforce rather than cancel.
    var axis = [0, 0, 0];
    nets.forEach(function (v) {
      var s = (v[0]*nets[0][0] + v[1]*nets[0][1] + v[2]*nets[0][2]) >= 0 ? 1 : -1;
      axis[0] += s*v[0]; axis[1] += s*v[1]; axis[2] += s*v[2];
    });
    var am = Math.sqrt(axis[0]*axis[0] + axis[1]*axis[1] + axis[2]*axis[2]) || 1;
    axis = [axis[0]/am, axis[1]/am, axis[2]/am];

    var segs = strokeIdx.map(function (si, si_i) {
      var from = spans[si][0] - a, to = spans[si][1] - 1 - a;
      var nv = nets[si_i];
      var proj = nv[0]*axis[0] + nv[1]*axis[1] + nv[2]*axis[2];
      var dx = pts[to][0] - pts[from][0];
      var sn = 0, sd = 0;
      for (var kk = from; kk <= to; kk++) {
        if (w2[kk] < opts.minOmega2) continue;
        var Mk3 = design(kk);
        for (var ii = 0; ii < 3; ii++) {
          var pr = Mk3[ii][0]*rBody[0] + Mk3[ii][1]*rBody[1] + Mk3[ii][2]*rBody[2];
          sn += (dyn[kk][ii] - pr)*(dyn[kk][ii] - pr);
          sd += dyn[kk][ii]*dyn[kk][ii];
        }
      }
      var lo = pts[from][1], hi = pts[from][1];
      for (kk = from; kk <= to; kk++) {
        if (pts[kk][1] < lo) lo = pts[kk][1];
        if (pts[kk][1] > hi) hi = pts[kk][1];
      }
      return {
        stroke: si,
        from: from,
        to: to,
        dir: proj >= 0 ? 1 : -1,
        netRotationDeg: nv,
        arcDeg: Math.sqrt(nv[0]*nv[0] + nv[1]*nv[1] + nv[2]*nv[2]),
        sweepCm: Math.abs(dx)*100,
        outOfPlaneCm: (hi - lo)*100,
        residual: sd > 0 ? Math.sqrt(sn/sd) : null
      };
    });

    return {
      ok: true,
      strokes: strokeIdx,
      segs: segs,
      i0: a, i1: b,
      t: readings.slice(a, b + 1).map(function (r) { return r.t - readings[a].t; }),
      pts: pts,
      armCm: Math.sqrt(rBody[0]*rBody[0] + rBody[1]*rBody[1] + rBody[2]*rBody[2])*100,
      rBody: rBody,
      residual: residual,
      extentCm: extent,
      outOfPlaneCm: outOfPlane,
      grounded: grounded,
      fitSamples: used
    };
  }

  /* ---------- entry point ---------- */

  var DEFAULTS = {
    burstGapSeconds: 1.5,   // PLAN.md Stage 3 puts within-burst gaps at 0.2-2.7 s
    padSeconds: 0.30,
    lookBackSeconds: 4.0,
    minOmega2: 9.0,         // (rad/s)^2 — below this the dynamic terms don't dominate
    // Rejection bounds. Measured arms across the corpus run 17-28 cm, so these
    // are wide enough to be a sanity check rather than a filter that shapes the
    // answer. Real casting sits at residual 0.48-0.65 — the pivot genuinely
    // moves — so the cutoff has to sit above that or it would reject the whole
    // corpus; the synthetic fixture reads 0.88.
    minArmM: 0.02,
    maxArmM: 2.00,
    maxResidual: 0.80,
    // Ridge weight, relative to the mean diagonal of the normal equations.
    // Small enough not to bias the observable directions, large enough to pin
    // the unobservable one to zero instead of to noise.
    ridge: 1e-4
  };

  /* How much of the motion the rigid-arm model actually explains. */
  function quality(residual) {
    if (residual === null) return "—";
    if (residual < 0.30) return "good";
    if (residual < 0.60) return "fair";
    return "poor";
  }

  /* Reconstructs every burst in a session.
     `spans` are [lo, hi) index pairs from CastrAnalysis.detectStrokes. */
  function reconstruct(readings, spans, options) {
    var o = Object.assign({}, DEFAULTS, options || {});
    var bias = gyroBias(readings);
    if (!spans.length) return { bias: bias.bias, stillSamples: bias.samples, bursts: [] };

    var groups = groupBursts(readings, spans, o.burstGapSeconds);
    var bursts = groups.map(function (g, i) {
      var r = reconstructBurst(readings, spans, g, bias.bias, o);
      r.index = i + 1;
      r.startTime = readings[spans[g[0]][0]].t - readings[0].t;
      return r;
    });
    return {
      bias: bias.bias,
      biasDegPerSec: bias.bias.slice(),
      stillSamples: bias.samples,
      bursts: bursts
    };
  }

  var API = {
    reconstruct: reconstruct,
    groupBursts: groupBursts,
    gyroBias: gyroBias,
    quality: quality,
    DEFAULTS: DEFAULTS,
    _internals: { qmul: qmul, qrot: qrot, qAlign: qAlign, solve3: solve3 }
  };

  if (typeof module === "object" && module.exports) module.exports = API;
  root.CastrReconstruct = API;
})(typeof globalThis !== "undefined" ? globalThis : this);
