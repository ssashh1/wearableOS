import json, numpy as np
from collections import defaultdict

rows = [json.loads(l) for l in open("motion_capture.jsonl")]
by_phase = defaultdict(list)
for r in rows:
    if r["datalen"] == 1917:
        by_phase[r["phase"]].append(bytes.fromhex(r["data_hex"])[24:])

STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
ROT = ["rot_twist", "rot_flex", "rot_wave"]


def phase_matrix(arrs, stride, off):
    """Return (Nsamples, stride) int16 matrix pooled across packets of a phase."""
    out = []
    for a in arrs:
        body = a[off:]
        n = len(body) // (2 * stride)
        m = np.frombuffer(body[:n*2*stride], dtype="<i2").reshape(n, stride)
        out.append(m)
    return np.vstack(out) if out else np.zeros((0, stride))


def show(stride, off):
    print(f"\n##### int16 stride={stride} off={off} bytes (={stride} ch) #####")
    print(f"{'ch':>3} | " + " ".join(f"{p[6:10]:>9}" for p in STILL) +
          "  ||  " + " ".join(f"{p[4:8]:>8}σ" for p in ROT))
    for ch in range(stride):
        means = []
        for p in STILL:
            M = phase_matrix(by_phase[p], stride, off)
            means.append(M[:, ch].mean() if len(M) else 0)
        stds = []
        for p in ROT:
            M = phase_matrix(by_phase[p], stride, off)
            stds.append(M[:, ch].std() if len(M) else 0)
        print(f"{ch:>3} | " + " ".join(f"{m:9.0f}" for m in means) +
              "  ||  " + " ".join(f"{s:9.0f}" for s in stds))


for stride in (6, 7, 8, 9):
    for off in (0, 2, 4, 8, 12, 16):
        show(stride, off)
