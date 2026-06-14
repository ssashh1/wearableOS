"""Rigorous accel/gyro localization using labeled motion phases.
Maps per-int16-position gravity-sensitivity (static poses) and rotation-activity.
"""
import json, numpy as np
from collections import defaultdict

rows = [json.loads(l) for l in open("motion_capture.jsonl")]
STILL = ["still_flat", "still_palmup", "still_thumbup", "still_fingersup"]
ROT = ["rot_twist", "rot_flex", "rot_wave"]


def load(dl):
    bp = defaultdict(list)
    n16 = dl // 2
    for r in rows:
        if r["datalen"] == dl:
            b = bytes.fromhex(r["data_hex"])[:n16*2]
            bp[r["phase"]].append(np.frombuffer(b, dtype="<i2").astype(float))
    return {k: np.array(v) for k, v in bp.items()}, n16


for DL in (1917, 1921):
    bp, n16 = load(DL)
    if not all(len(bp.get(p, [])) for p in STILL+ROT):
        print(f"datalen {DL}: missing phases"); continue
    # per-position static mean per pose, and rotation std (packet-to-packet)
    static_means = np.array([bp[p].mean(0) for p in STILL])   # (4, n16)
    grav_sens = static_means.max(0) - static_means.min(0)     # (n16,)
    still_base = static_means.mean(0)
    rot_std = np.array([bp[p].std(0) for p in ROT]).mean(0)    # (n16,)

    print(f"\n################ datalen={DL} ({n16} int16) ################")
    print("TOP 30 gravity-sensitive positions (accel candidates):")
    print(" pos  byte | flat  palm  thmb  fing | gravΔ  stillμ  rotσ")
    for p in np.argsort(grav_sens)[::-1][:30]:
        sm = static_means[:, p]
        print(f" {p:4d} {p*2:5d} | {sm[0]:6.0f}{sm[1]:6.0f}{sm[2]:6.0f}{sm[3]:6.0f} | {grav_sens[p]:6.0f} {still_base[p]:7.0f} {rot_std[p]:6.0f}")

    # spatial concentration of gravity sensitivity
    hi = np.where(grav_sens > grav_sens.mean() + 2*grav_sens.std())[0]
    print(f"\nHigh-gravity positions (byte offsets): {sorted(set((hi*2).tolist()))[:40]}")
    print(f"  -> min byte {hi.min()*2 if len(hi) else '-'}, max byte {hi.max()*2 if len(hi) else '-'}")
