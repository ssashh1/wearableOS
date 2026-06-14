"""Crack the 1921-byte IMU packet: find stride/offset, separate accel (gravity) from gyro (rotation)."""
import json, numpy as np
from collections import defaultdict

rows = [json.loads(l) for l in open("motion_capture.jsonl")]
STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
ROT = ["rot_twist", "rot_flex", "rot_wave"]

bp = defaultdict(list)
for r in rows:
    if r["datalen"] == 1921:
        bp[r["phase"]].append(bytes.fromhex(r["data_hex"]))


def channels(arrs, stride, off, ch):
    vals = []
    for a in arrs:
        body = a[off:]
        n = len(body)//2//stride
        m = np.frombuffer(body[:n*stride*2], dtype="<i2").reshape(n, stride)
        vals.append(m[:, ch].astype(float))
    return np.concatenate(vals) if vals else np.array([])


def score(stride, off):
    rows_out = []
    for ch in range(stride):
        sm = [channels(bp[p], stride, off, ch).mean() for p in STILL]
        rs = [channels(bp[p], stride, off, ch).std() for p in ROT]
        grav = max(sm) - min(sm)
        rows_out.append((ch, sm, grav, rs))
    return rows_out


# Try strides; print the ones where ~3 channels have big gravity range
for stride in (6, 7, 8, 9, 12):
    for off in range(16, 40, 2):
        res = score(stride, off)
        gravs = sorted([r[2] for r in res], reverse=True)
        # heuristic: want a clear gap after 3 strong gravity channels
        if len(gravs) >= 6 and gravs[2] > 6000 and gravs[3] < gravs[2]*0.7:
            print(f"\n##### stride={stride} off={off} — candidate (3 accel channels stand out) #####")
            print(f"{'ch':>3} | {'flat':>7}{'palm':>7}{'thmb':>7}{'fing':>7} | {'gravΔ':>7} || {'twis':>6}{'flex':>6}{'wave':>6}")
            for ch, sm, grav, rs in res:
                tag = "ACCEL?" if grav > 6000 else ("GYRO?" if max(rs) > 8000 and grav < 4000 else "")
                print(f"{ch:>3} | {sm[0]:7.0f}{sm[1]:7.0f}{sm[2]:7.0f}{sm[3]:7.0f} | {grav:7.0f} || {rs[0]:6.0f}{rs[1]:6.0f}{rs[2]:6.0f}  {tag}")
