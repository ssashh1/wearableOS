import json, numpy as np
from collections import defaultdict

rows = [json.loads(l) for l in open("motion_capture.jsonl")]
by_phase = defaultdict(list)
for r in rows:
    if r["datalen"] == 1917:
        by_phase[r["phase"]].append(bytes.fromhex(r["data_hex"]))  # full data, incl header

STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
ROT = ["rot_twist", "rot_flex", "rot_wave"]


def blocks(data, nblocks, off):
    """Split data[off:] into nblocks equal int16 blocks; return per-block (mean,std) lists."""
    body = data[off:]
    total = len(body) // 2
    per = total // nblocks
    arr = np.frombuffer(body[:per*nblocks*2], dtype="<i2").reshape(nblocks, per)
    return arr


def analyze(nblocks, off):
    print(f"\n##### BLOCKED int16: {nblocks} blocks, off={off}, blocklen~{(1893-off)//2//nblocks} samples #####")
    print(f"{'blk':>3} | " + " ".join(f"{p[6:10]:>9}" for p in STILL) +
          "  ||  " + " ".join(f"{p[4:8]:>8}σ" for p in ROT))
    for b in range(nblocks):
        means = []
        for p in STILL:
            vs = [blocks(d, nblocks, off)[b] for d in by_phase[p]]
            means.append(np.concatenate(vs).mean() if vs else 0)
        stds = []
        for p in ROT:
            vs = [blocks(d, nblocks, off)[b] for d in by_phase[p]]
            stds.append(np.concatenate(vs).std() if vs else 0)
        print(f"{b:>3} | " + " ".join(f"{m:9.0f}" for m in means) +
              "  ||  " + " ".join(f"{s:9.0f}" for s in stds))


# header is data[0:24]; array starts at 24. try splitting from 24 (and a couple sub-header offsets)
for off in (24, 32, 40):
    for nb in (6, 3):
        analyze(nb, off)
