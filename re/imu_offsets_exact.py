"""Pin EXACT block offsets. The gyro region is a smooth ramp during rotation;
its precise start byte = where lag-1 autocorr jumps to ~0.9. Likewise find accel.
Also: a 3-byte error in a 100-sample block barely moves the mean, so distinguish
82 vs 85 by checking which start gives the LOWEST within-still time-variance and
the cleanest sphere fit (true axis is maximally quiet)."""
import json
import numpy as np
from collections import defaultdict

CAP = "fixtures/motion_capture.jsonl"
STILL = ["still_flat","still_palmup","still_thumbup","still_fingersup"]
ROT=["rot_twist","rot_flex","rot_wave"]
by_phase = defaultdict(list)
with open(CAP) as f:
    for line in f:
        o=json.loads(line)
        if o["cmd"]==41 and o["datalen"]==1917:
            by_phase[o["phase"]].append(bytes.fromhex(o["data_hex"]))
NS=100

# Precise gyro start: scan byte, read 100 LE int16, lag-1 corr in rot packets.
def lag1(start):
    cs=[]
    for p in ROT:
        for d in by_phase[p]:
            v=np.frombuffer(d[start:start+NS*2],dtype="<i2").astype(float)
            v=v-v.mean()
            if v.std()<1e-6: continue
            a,b=v[:-1],v[1:]
            den=np.sqrt((a*a).sum()*(b*b).sum())
            if den>0: cs.append((a*b).sum()/den)
    return np.mean(cs)
print("lag-1 autocorr (rotation) near gyro-X start (byte 680-692):")
for s in range(678,694):
    print(f"  byte{s}: {lag1(s):+.3f}")

# Accel block: choose start minimizing within-still time variance (true axis quiet)
def still_noise(start):
    ns=[]
    for p in STILL:
        for d in by_phase[p]:
            v=np.frombuffer(d[start:start+NS*2],dtype="<i2").astype(float)
            ns.append(v.std())
    return np.mean(ns)
print("\nWithin-still time-noise near accel-X (byte 78-90) [lower=cleaner axis]:")
for s in range(78,92):
    print(f"  byte{s}: noise={still_noise(s):6.1f}")

print("\nWithin-still time-noise near accel-Y (byte 278-290):")
for s in range(278,292):
    print(f"  byte{s}: noise={still_noise(s):6.1f}")
print("\nWithin-still time-noise near accel-Z (byte 478-490):")
for s in range(478,492):
    print(f"  byte{s}: noise={still_noise(s):6.1f}")
