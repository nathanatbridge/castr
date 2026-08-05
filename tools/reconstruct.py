"""Reconstruct sensor trajectory from IMU data, assuming rotation about a pivot.

Position is NOT obtained by double-integrating acceleration -- that drifts
without bound. Instead the sensor is modelled as a point on a rigid arm of fixed
length turning about a pivot, so position follows from orientation (well
conditioned) times a constant lever arm. The lever arm itself is measured from
the centripetal acceleration, not assumed.
"""
import sys, csv, math, json

G = 9.80665


# ---------- quaternion helpers (w, x, y, z) ----------
def qmul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw*bw - ax*bx - ay*by - az*bz,
            aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw)


def qnorm(q):
    n = math.sqrt(sum(c*c for c in q))
    return tuple(c/n for c in q)


def qrot(q, v):
    """Rotate vector v by quaternion q (body -> world)."""
    w, x, y, z = q
    vx, vy, vz = v
    tx = 2*(y*vz - z*vy)
    ty = 2*(z*vx - x*vz)
    tz = 2*(x*vy - y*vx)
    return (vx + w*tx + (y*tz - z*ty),
            vy + w*ty + (z*tx - x*tz),
            vz + w*tz + (x*ty - y*tx))


def qconj(q):
    return (q[0], -q[1], -q[2], -q[3])


def q_from_axis_angle(axis, ang):
    n = math.sqrt(sum(c*c for c in axis))
    if n < 1e-12:
        return (1.0, 0.0, 0.0, 0.0)
    s = math.sin(ang/2)/n
    return (math.cos(ang/2), axis[0]*s, axis[1]*s, axis[2]*s)


def q_align(v_from, v_to):
    """Shortest-arc quaternion rotating v_from onto v_to (both unit)."""
    d = sum(a*b for a, b in zip(v_from, v_to))
    if d > 0.999999:
        return (1.0, 0.0, 0.0, 0.0)
    if d < -0.999999:
        axis = (1, 0, 0) if abs(v_from[0]) < 0.9 else (0, 1, 0)
        cx = (v_from[1]*axis[2]-v_from[2]*axis[1],
              v_from[2]*axis[0]-v_from[0]*axis[2],
              v_from[0]*axis[1]-v_from[1]*axis[0])
        return q_from_axis_angle(cx, math.pi)
    cx = (v_from[1]*v_to[2]-v_from[2]*v_to[1],
          v_from[2]*v_to[0]-v_from[0]*v_to[2],
          v_from[0]*v_to[1]-v_from[1]*v_to[0])
    return qnorm((1.0 + d, cx[0], cx[1], cx[2]))


def solve3(A, b):
    M = [A[i][:] + [b[i]] for i in range(3)]
    for c in range(3):
        p = max(range(c, 3), key=lambda r: abs(M[r][c]))
        M[c], M[p] = M[p], M[c]
        if abs(M[c][c]) < 1e-14:
            return None
        for r in range(3):
            if r == c:
                continue
            f = M[r][c]/M[c][c]
            for k in range(c, 4):
                M[r][k] -= f*M[c][k]
    return [M[i][3]/M[i][i] for i in range(3)]


# ---------- load ----------
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
from datetime import datetime
ts = [datetime.strptime(r["time"], "%Y-%m-%d %H:%M:%S.%f") for r in rows]
T = [(t - ts[0]).total_seconds() for t in ts]
acc = [(float(r["AccX(g)"]), float(r["AccY(g)"]), float(r["AccZ(g)"])) for r in rows]
gyr = [(math.radians(float(r["AsX(°/s)"])), math.radians(float(r["AsY(°/s)"])),
        math.radians(float(r["AsZ(°/s)"]))) for r in rows]
N = len(rows)
am = [math.sqrt(sum(c*c for c in a)) for a in acc]
gmag = [math.sqrt(sum(c*c for c in g)) for g in gyr]

# ---------- gyro bias from the still periods ----------
still = [i for i in range(N) if gmag[i] < math.radians(3) and abs(am[i]-1.0) < 0.05]
bias = tuple(sum(gyr[i][k] for i in still)/len(still) for k in range(3))
gyr = [tuple(g[k] - bias[k] for k in range(3)) for g in gyr]
gmag = [math.sqrt(sum(c*c for c in g)) for g in gyr]

# ---------- events ----------
dev = [abs(v-1.0) for v in am]
act = [i for i, v in enumerate(dev) if v > 0.15]
bursts, s, p = [], act[0], act[0]
for i in act[1:]:
    if i - p > 60:
        bursts.append((s, p))
        s = i
    p = i
bursts.append((s, p))

out_events = []
for idx, (a0, b0) in enumerate(bursts, 1):
    # pad so the trace starts and ends at rest
    a = max(0, a0 - 60)
    b = min(N-1, b0 + 60)

    # --- initial orientation: align measured gravity to world up (+Z) ---
    pre = [i for i in range(max(0, a0-120), a0) if gmag[i] < math.radians(5)]
    if len(pre) < 10:
        pre = list(range(max(0, a0-40), a0))
    gv = [sum(acc[i][k] for i in pre)/len(pre) for k in range(3)]
    n = math.sqrt(sum(c*c for c in gv))
    gv = [c/n for c in gv]
    q = q_align(gv, (0.0, 0.0, 1.0))

    # --- integrate orientation, collecting dynamic acceleration ---
    quats, dyn, w2, wlist = [], [], [], []
    for i in range(a, b+1):
        quats.append(q)
        gb = qrot(qconj(q), (0.0, 0.0, 1.0))          # gravity direction in body frame
        dyn.append(tuple((acc[i][k] - gb[k]) * G for k in range(3)))
        w2.append(gmag[i]**2)
        wlist.append(gyr[i])
        if i < b:
            dt = T[i+1] - T[i]
            wv = gyr[i]
            ang = gmag[i] * dt
            if ang > 1e-12:
                q = qnorm(qmul(q, q_from_axis_angle(wv, ang)))

    # --- angular acceleration, lightly smoothed (finite differences are noisy) ---
    sidx = list(range(a, b+1))
    alpha = []
    for k in range(len(sidx)):
        k0, k1 = max(0, k-2), min(len(sidx)-1, k+2)
        dt = T[sidx[k1]] - T[sidx[k0]]
        alpha.append(tuple((wlist[k1][j]-wlist[k0][j])/dt if dt > 0 else 0.0
                           for j in range(3)))

    # --- lever arm from the full rigid-body model ---
    #   a_dyn = w x (w x r) + alpha x r
    #         = (w w^T - |w|^2 I) r + [alpha]_x r
    # Both terms are linear in r, so this is one linear least-squares solve.
    # Fitting centripetal alone leaves the tangential term in the residual and
    # biases the radius.
    ATA = [[0.0]*3 for _ in range(3)]
    ATb = [0.0]*3
    used = 0
    for k in range(len(dyn)):
        if w2[k] < 9.0:        # need >3 rad/s for the dynamic terms to dominate
            continue
        used += 1
        w = wlist[k]
        al = alpha[k]
        Mk = [[w[i]*w[j] - (w2[k] if i == j else 0.0) for j in range(3)] for i in range(3)]
        Mk[0][1] += -al[2]; Mk[0][2] += al[1]
        Mk[1][0] += al[2];  Mk[1][2] += -al[0]
        Mk[2][0] += -al[1]; Mk[2][1] += al[0]
        for i in range(3):
            for j in range(3):
                ATA[i][j] += sum(Mk[m][i]*Mk[m][j] for m in range(3))
            ATb[i] += sum(Mk[m][i]*dyn[k][m] for m in range(3))
    # Only the part of the arm perpendicular to the rotation axis is
    # observable: w x (w x r) and alpha x r both annihilate the component along
    # w, so a swing that holds one axis leaves it with no trace in the
    # acceleration at all. Without a ridge term the solve fills it with whatever
    # fits the noise -- on the synthetic fixture that returned 59.9 cm for an arm
    # whose observable part is 27.8 cm, while still fitting to a residual of
    # 0.009. The ridge takes the minimum-norm solution instead, which drops the
    # unobservable component rather than inventing one. What comes back is the
    # swing radius: the part that actually sets the path.
    RIDGE = 1e-4
    lam = RIDGE * sum(ATA[i][i] for i in range(3)) / 3
    for i in range(3):
        ATA[i][i] += lam

    r_body = solve3(ATA, ATb) if used >= 25 else None

    if r_body is None:
        out_events.append(dict(n=idx, ok=False))
        continue

    r_len = math.sqrt(sum(c*c for c in r_body))

    # --- trajectory: pivot at origin, sensor at R(t)*r_body ---
    raw = [qrot(quats[k], r_body) for k in range(len(quats))]

    # Gravity fixes which way is up, but leaves the heading free. Rotate about
    # the vertical so the swing's dominant horizontal direction becomes +X:
    # then the side view (XZ) carries the arc and the top view (XY) shows
    # departure from the plane, rather than both being arbitrary slices.
    mx = sum(p[0] for p in raw)/len(raw)
    my = sum(p[1] for p in raw)/len(raw)
    sxx = sum((p[0]-mx)**2 for p in raw)
    syy = sum((p[1]-my)**2 for p in raw)
    sxy = sum((p[0]-mx)*(p[1]-my) for p in raw)
    theta = 0.5*math.atan2(2*sxy, sxx-syy)      # principal horizontal axis
    ct, st = math.cos(-theta), math.sin(-theta)
    pts = []
    for p_ in raw:
        x = p_[0]*ct - p_[1]*st
        y = p_[0]*st + p_[1]*ct
        pts.append([round(x, 4), round(y, 4), round(p_[2], 4)])
    # keep the arc sweeping left-to-right for readability
    if pts[-1][0] < pts[0][0]:
        pts = [[-p_[0], -p_[1], p_[2]] for p_ in pts]

    # residual: how well does a rigid arm explain the measured acceleration?
    num = den = 0.0
    for k in range(len(dyn)):
        if w2[k] < 9.0:
            continue
        w = wlist[k]
        al = alpha[k]
        Mk = [[w[i]*w[j] - (w2[k] if i == j else 0.0) for j in range(3)] for i in range(3)]
        Mk[0][1] += -al[2]; Mk[0][2] += al[1]
        Mk[1][0] += al[2];  Mk[1][2] += -al[0]
        Mk[2][0] += -al[1]; Mk[2][1] += al[0]
        pred = [sum(Mk[i][j]*r_body[j] for j in range(3)) for i in range(3)]
        num += sum((dyn[k][j]-pred[j])**2 for j in range(3))
        den += sum(dyn[k][j]**2 for j in range(3))
    resid = math.sqrt(num/den) if den > 0 else None

    out_events.append(dict(
        n=idx, ok=True,
        t0=round(T[a], 3), t1=round(T[b], 3),
        tStart=round(T[a0]-T[a], 3), tEnd=round(T[b0]-T[a], 3),
        t=[round(T[i]-T[a], 4) for i in range(a, b+1)],
        pts=pts,
        w=[round(math.degrees(gmag[i]), 1) for i in range(a, b+1)],
        am=[round(am[i], 3) for i in range(a, b+1)],
        radius=round(r_len*100, 1),
        rbody=[round(c, 4) for c in r_body],
        residual=round(resid, 3) if resid is not None else None,
        peakW=round(math.degrees(max(gmag[a0:b0+1])), 0),
        samples=b-a+1))

meta = dict(
    biasDegPerSec=[round(math.degrees(c), 4) for c in bias],
    stillSamples=len(still),
    file=sys.argv[1])
print(json.dumps(dict(meta=meta, events=out_events), separators=(",", ":")))
