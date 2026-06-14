"""Map all smooth single-axis blocks: slide a window over the int16-LE stream
(odd-aligned, start=1) and compute lag-1 autocorrelation within a rotation packet
(averaged over packets). Real motion axis blocks => high lag-1 corr (smooth).
Also test accel block locations via gravity-direction change across still poses."""
import json
import numpy as np
from collections import defaultdict

CAP = "fixtures/motion_capture.jsonl"
STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
ROT = ["rot_twist", "rot_flex", "rot_wave"]
by_phase = defaultdict(list)
with open(CAP) as f:
    for line in f:
        o = json.loads(line)
        if o["cmd"] == 41 and o["datalen"] == 1917:
            by_phase[o["phase"]].append(bytes.fromhex(o["data_hex"]))

def stream(d, start):
    n = (1917 - start)//2
    return np.frombuffer(d[start:start+n*2], dtype="<i2").astype(float)

# Use odd alignment start=1 (matches byte 685 anchor: 685 is odd).
START_ALIGN = 1
# lag-1 autocorr per int16 position over a 50-sample window, averaged over rot packets
def smoothness_map(phases, win=40):
    streams = []
    for p in phases:
        for d in by_phase[p]:
            streams.append(stream(d, START_ALIGN))
    S = np.array(streams)  # (npkts, n)
    n = S.shape[1]
    sm = np.full(n, np.nan)
    for i in range(n - win):
        seg = S[:, i:i+win]
        # mean lag-1 corr across packets
        cs = []
        for row in seg:
            r = row - row.mean()
            if r.std() < 1e-6:
                continue
            a, b = r[:-1], r[1:]
            denom = (np.sqrt((a**2).sum()*(b**2).sum()))
            if denom>0:
                cs.append((a*b).sum()/denom)
        sm[i] = np.mean(cs) if cs else 0
    return sm

sm_rot = smoothness_map(ROT)
# byte position of int16 index i = START_ALIGN + 2*i
print("Smoothness (lag-1 autocorr) map during ROTATION, win=40 int16:")
print("Showing positions where corr>0.6 (smooth motion axis blocks):")
hi = np.where(sm_rot > 0.6)[0]
# contiguous runs
if len(hi):
    runs=[]; s=hi[0]; prev=hi[0]
    for x in hi[1:]:
        if x!=prev+1: runs.append((s,prev)); s=x
        prev=x
    runs.append((s,prev))
    for a,b in runs:
        print(f"  int16 idx {a}..{b}  => bytes {START_ALIGN+2*a}..{START_ALIGN+2*b}  (len {b-a+1})")

# Also a coarse profile every 25 positions
print("\nCoarse smoothness profile (byte: corr):")
for i in range(0, len(sm_rot), 25):
    b = START_ALIGN + 2*i
    print(f"  byte{b:4d}: {sm_rot[i]:+.2f}", end="   ")
    if (i//25)%4==3: print()
print()
