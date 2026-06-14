"""Verify sample rate (100 samp <-> packet dt) and map UNKNOWN regions of the 1917B packet."""
import json
import numpy as np
from collections import defaultdict

CAP="fixtures/motion_capture.jsonl"
rows=[]; by_phase=defaultdict(list)
with open(CAP) as f:
    for line in f:
        o=json.loads(line)
        if o["cmd"]==41 and o["datalen"]==1917:
            rows.append(o); by_phase[o["phase"]].append(bytes.fromhex(o["data_hex"]))

# timing per contiguous phase
print("Sample-rate check (per phase, packet wall dt):")
for p in by_phase:
    ww=sorted(r["wall"] for r in rows if r["phase"]==p)
    d=np.diff(ww); d=d[d<2]  # drop phase-boundary gaps
    if len(d):
        print(f"  {p:16s} n={len(d)+1:2d} median dt={np.median(d):.3f}s -> fs={100/np.median(d):.0f}Hz")

# Map regions: header(0..24?), accel blocks, gyro blocks, gaps, tail.
# Per-int16 across-packet variability + within-still constancy to classify.
d0=by_phase["still_flat"][0]
print(f"\nKnown structure (byte ranges, 100 samp int16 LE blocks):")
print("  [0:24]   header (unix@4, subsec@8, hr@14, rrnum@15, rr@16..)")
print("  [24:82]  GAP1 (58B) unknown - between header and accelX")
print("  [82:282] ACCEL X (100 int16)")
print("  [282:482]ACCEL Y")
print("  [482:682]ACCEL Z  (ends 682)")
print("  [682:685]GAP2 (3B) unknown")
print("  [685:885]GYRO X (100 int16)")
print("  [885:1085]GYRO Y")
print("  [1085:1285]GYRO Z (ends 1285)")
print("  [1285:1917]TAIL (632B) unknown")

# Characterize GAP1 (24..82) and TAIL (1285..1917): constant? varies with motion?
def region_profile(lo,hi):
    # per-byte across-packet std (all phases) and whether changes with motion
    allp=[]
    for p in by_phase:
        for d in by_phase[p]:
            allp.append(np.frombuffer(d[lo:hi],dtype=np.uint8))
    A=np.array(allp)
    constbytes=int((A.std(0)<0.5).sum())
    return A.shape[1], constbytes, A.std(0).mean()
for name,lo,hi in [("GAP1",24,82),("ACCELend-GAP2",682,685),("TAIL",1285,1917)]:
    n,cb,ms=region_profile(lo,hi)
    print(f"\n{name} [{lo}:{hi}] {n}B: {cb} constant bytes, mean byte-std={ms:.1f}")

# Does TAIL contain another smooth motion-like block? check lag1 in rotation
def lag1(start,nsamp=100):
    cs=[]
    for p in ["rot_twist","rot_flex","rot_wave"]:
        for d in by_phase[p]:
            if start+nsamp*2>1917: continue
            v=np.frombuffer(d[start:start+nsamp*2],dtype="<i2").astype(float); v=v-v.mean()
            if v.std()<1e-6: continue
            a,b=v[:-1],v[1:]; den=np.sqrt((a*a).sum()*(b*b).sum())
            if den>0: cs.append((a*b).sum()/den)
    return np.mean(cs) if cs else 0
print("\nTAIL smoothness scan (odd-aligned, looking for more axis blocks):")
for s in range(1285,1717,50):
    print(f"  byte{s}: lag1={lag1(s):+.2f}")
