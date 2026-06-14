"""Bound gyro scale by net-rotation consistency over each rotation phase.
Integrate signed gyro (per axis) over a whole phase and compare to net change in
gravity direction. Also test: under openwhoop K=1/15, do the implied dps values
during 'still' phases sit near 0 and during rotation reach plausible wrist speeds?"""
import json
import numpy as np
from collections import defaultdict

CAP="fixtures/motion_capture.jsonl"
ROT=["rot_twist","rot_flex","rot_wave"]
STILL=["still_flat","still_palmup","still_thumbup","still_fingersup"]
by_phase=defaultdict(list)
with open(CAP) as f:
    for line in f:
        o=json.loads(line)
        if o["cmd"]==41 and o["datalen"]==1917:
            by_phase[o["phase"]].append(bytes.fromhex(o["data_hex"]))
NS=100; AOFF=[82,282,482]; GOFF=[685,885,1085]; ASCALE=4096.0; DT=0.0096
def axis(d,s): return np.frombuffer(d[s:s+NS*2],dtype="<i2").astype(float)

# Plausibility under candidate scales: peak wrist angular speed during rotation
print("Peak |gyro| (LSB) per rotation phase -> implied dps under candidate K:")
cands={"ow ÷15":1/15,"±1000dps":1000/32768,"±2000dps":2000/32768,"±500dps":500/32768}
for p in ROT:
    peak=max(np.linalg.norm(np.stack([axis(d,o) for o in GOFF],axis=1),axis=1).max() for d in by_phase[p])
    s=f"  {p:12s} peakLSB={peak:5.0f} -> "
    s+= "  ".join(f"{k}:{peak*K:6.0f}dps" for k,K in cands.items())
    print(s)
# still-phase gyro should be ~0 dps
print("\nStill-phase median |gyro| (LSB) -> implied dps (should be near 0):")
for p in STILL:
    med=np.median(np.concatenate([np.linalg.norm(np.stack([axis(d,o) for o in GOFF],axis=1),axis=1) for d in by_phase[p]]))
    print(f"  {p:14s} medLSB={med:4.0f} -> ow÷15:{med/15:.1f}dps")

# Phase-level net rotation consistency (smoother than per-sample):
# Over full phase, sum |dtheta_grav| (total path) vs sum |gyro_perp|*dt.
print("\nPhase-level total-path consistency (K=total_grav_angle/total_gyro_integral):")
for p in ROT:
    tot_ang=0.0; tot_int=0.0
    for d in by_phase[p]:
        a=np.stack([axis(d,o) for o in AOFF],axis=1)/ASCALE
        g=np.stack([axis(d,o) for o in GOFF],axis=1)
        gh=a/np.linalg.norm(a,axis=1,keepdims=True)
        dth=np.arccos(np.clip(np.sum(gh[:-1]*gh[1:],axis=1),-1,1))
        gmid=gh[:-1]+gh[1:]; gmid/=np.linalg.norm(gmid,axis=1,keepdims=True)
        wperp=np.linalg.norm(g[:-1]-np.sum(g[:-1]*gmid,axis=1,keepdims=True)*gmid,axis=1)
        tot_ang+=dth.sum(); tot_int+=(wperp*DT).sum()
    K=tot_ang/tot_int*180/np.pi if tot_int>0 else 0
    print(f"  {p:12s} totGravAngle={np.degrees(tot_ang):7.0f}deg totGyroInt={tot_int:8.0f}LSB.s -> K={K:.4f}dps/LSB")
