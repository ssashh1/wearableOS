"""FINAL verified type-43 IMU decoder + evidence table.
Layout: int16 LE, 100 samp/axis (~104 Hz).
 ACCEL X@82 Y@282 Z@482 ; scale 4096 LSB/g
 GYRO  X@685 Y@885 Z@1085; scale UNRESOLVED (plausibility ~ openwhoop ÷15)
"""
import json
import numpy as np
from collections import defaultdict

CAP="fixtures/motion_capture.jsonl"
STILL=["still_flat","still_palmup","still_thumbup","still_fingersup"]
ROT=["rot_twist","rot_flex","rot_wave"]
by_phase=defaultdict(list)
with open(CAP) as f:
    for line in f:
        o=json.loads(line)
        if o["cmd"]==41 and o["datalen"]==1917:
            by_phase[o["phase"]].append(bytes.fromhex(o["data_hex"]))
NS=100; AOFF=[82,282,482]; GOFF=[685,885,1085]; AS=4096.0
def ax(d,s): return np.frombuffer(d[s:s+NS*2],dtype="<i2").astype(float)

print("=== ACCEL per-phase mean gravity vector (g units, scale=4096 LSB/g) ===")
print(f"{'phase':16s} {'gx':>6}{'gy':>6}{'gz':>6}  {'|g|':>6}  {'(quiet-pkt|g|)':>14}")
for p in STILL:
    # all packets
    v=np.array([[ax(d,o).mean() for o in AOFF] for d in by_phase[p]])/AS
    mean=v.mean(0); mag=np.linalg.norm(mean)
    # quiet packets only (low within-packet noise)
    noise=np.array([np.mean([ax(d,o).std() for o in AOFF]) for d in by_phase[p]])
    q=v[noise<np.percentile(noise,50)]
    qmag=np.linalg.norm(q,axis=1).mean()
    print(f"{p:16s} {mean[0]:6.2f}{mean[1]:6.2f}{mean[2]:6.2f}  {mag:6.2f}  {qmag:14.3f}")

print("\n=== GYRO per-phase: still mean (should ~0) & rotation std (LSB) ===")
for p in STILL:
    m=np.array([[ax(d,o).mean() for o in GOFF] for d in by_phase[p]]).mean(0)
    print(f"  STILL {p:16s} mean LSB=({m[0]:6.1f},{m[1]:6.1f},{m[2]:6.1f})")
for p in ROT:
    s=[np.concatenate([ax(d,o) for d in by_phase[p]]).std() for o in GOFF]
    print(f"  ROT   {p:16s} std  LSB=({s[0]:6.0f},{s[1]:6.0f},{s[2]:6.0f})")
