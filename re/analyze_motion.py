"""Crack the accel/gyro layout using labeled motion phases.
Accel channels: ~constant within a still phase, gravity vector magnitude ~const
  across orientations, redistributes between the 4 static poses.
Gyro channels: ~0 mean when still, high std during their rotation phase.
"""
import json
import struct
import statistics as st
from collections import defaultdict

rows = [json.loads(l) for l in open("motion_capture.jsonl")]
# group array bytes (data[24:]) by phase; keep only the dominant datalen (1917)
by_phase = defaultdict(list)
for r in rows:
    if r["datalen"] == 1917:
        by_phase[r["phase"]].append(bytes.fromhex(r["data_hex"])[24:])

STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
ROT = ["rot_twist", "rot_flex", "rot_wave"]


def channel_pool(arrs, dtype, stride, off, ch):
    """Pool all samples for channel `ch` across packets in a phase."""
    vals = []
    if dtype == "f":
        sz = 4
    else:
        sz = 2
    for a in arrs:
        body = a[off:]
        n = len(body) // (sz * stride)
        for i in range(n):
            base = (i * stride + ch) * sz
            chunk = body[base:base+sz]
            if len(chunk) == sz:
                vals.append(struct.unpack("<" + dtype, chunk)[0])
    return vals


def try_config(dtype, stride, off):
    print(f"\n##### dtype={dtype} stride={stride} off={off} #####")
    # per channel: mean in each still phase, std in each rotation phase
    hdr = f"{'ch':>3} | " + " ".join(f"{p[6:10]:>8}" for p in STILL) + " || " + " ".join(f"{p[4:8]:>7}std" for p in ROT)
    print(hdr)
    chstats = []
    for ch in range(stride):
        still_means = [st.mean(channel_pool(by_phase[p], dtype, stride, off, ch)) if by_phase[p] else 0 for p in STILL]
        rot_stds = [st.pstdev(channel_pool(by_phase[p], dtype, stride, off, ch)) if by_phase[p] else 0 for p in ROT]
        chstats.append((still_means, rot_stds))
        sm = " ".join(f"{m:8.2f}" for m in still_means)
        rs = " ".join(f"{s:7.1f}" for s in rot_stds)
        print(f"{ch:>3} | {sm} || {rs}")
    return chstats


# Try the most likely layouts
for dtype, stride, off in [("f", 6, 0), ("f", 6, 8), ("h", 6, 0), ("h", 6, 8), ("f", 7, 0), ("h", 9, 0)]:
    try_config(dtype, stride, off)
