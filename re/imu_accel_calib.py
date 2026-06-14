"""Proper accelerometer calibration: per-PACKET gravity vectors (not pose means).
Select still packets with low within-packet time-variance (truly static), then
solve for per-axis bias (bx,by,bz) and common gravity magnitude G that makes
|v - b| = G for ALL such packets (overdetermined -> meaningful residual).
Axes @ bytes 82/282/482, int16 LE, 100 samples."""
import json
import numpy as np
from collections import defaultdict

CAP = "fixtures/motion_capture.jsonl"
STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
by_phase = defaultdict(list)
with open(CAP) as f:
    for line in f:
        o = json.loads(line)
        if o["cmd"] == 41 and o["datalen"] == 1917:
            by_phase[o["phase"]].append(bytes.fromhex(o["data_hex"]))
NS=100; OFF=[82,282,482]
def block(d,s): return np.frombuffer(d[s:s+NS*2],dtype="<i2").astype(float)

# Build per-packet vectors with within-packet noise; keep "still" ones (low time std).
vecs=[]; noises=[]
for p in STILL:
    for d in by_phase[p]:
        axes=[block(d,o) for o in OFF]
        v=np.array([a.mean() for a in axes])
        noise=np.mean([a.std() for a in axes])
        vecs.append(v); noises.append(noise)
vecs=np.array(vecs); noises=np.array(noises)
# keep quietest 60%
thr=np.percentile(noises,60)
mask=noises<=thr
Vq=vecs[mask]
print(f"{len(vecs)} still packets; keeping {mask.sum()} with within-packet noise<={thr:.0f} LSB")

# Solve bias+G by minimizing sum((|v-b|^2 - G^2))? Use iterative: ellipsoid->sphere.
# Simple Gauss-Newton on r_i=|v_i-b|-G.
def fit(V):
    b=V.mean(0).copy(); G=np.linalg.norm(V-b,axis=1).mean()
    for _ in range(200):
        d=V-b; r=np.linalg.norm(d,axis=1)
        res=r-G
        # jacobian wrt b: -d/r ; wrt G: -1
        u=d/r[:,None]
        J=np.hstack([-u, -np.ones((len(V),1))])
        delta=np.linalg.lstsq(J, -res, rcond=None)[0]
        b=b+delta[:3]; G=G+delta[3]
    return b,G
b,G=fit(Vq)
r=np.linalg.norm(Vq-b,axis=1)
print(f"\nFitted bias b=({b[0]:.0f},{b[1]:.0f},{b[2]:.0f}) LSB, gravity |g|=G={G:.0f} LSB")
print(f"residual |v-b|: mean={r.mean():.0f} std={r.std():.0f}  ({100*r.std()/G:.1f}% of G) "
      f"min={r.min():.0f} max={r.max():.0f}")
print(f"=> accel scale = {G:.0f} LSB/g (after removing per-axis bias)")
print(f"   without bias removal, raw |v| mean over still = {np.linalg.norm(Vq,axis=1).mean():.0f} "
      f"std={np.linalg.norm(Vq,axis=1).std():.0f}")
# Common MEMS accel scales: 2048(±16g),4096(±8g),8192(±4g),16384(±2g) LSB/g
for s,rng in [(2048,16),(4096,8),(8192,4),(16384,2)]:
    print(f"   if {s} LSB/g (±{rng}g): G implies {G/s:.2f}g")
