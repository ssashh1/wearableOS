"""Pin the Gen4 type-43 gyro scale (deg/s per LSB) from a controlled-rotation capture.

Each rotation phase = exactly 2 full turns (720 deg) about ONE axis. For the dominant gyro
channel: angle = K * dt * sum(raw - bias)  ->  K = 720 / (dt * |sum(raw-bias)|).
bias from the 'still' phase; dt = phase_duration / total_samples. The three axes' K should agree.
gyro in data: X@685 Y@885 Z@1085, 100 x int16 LE each (data = frame after type/seq/cmd).
"""
import json
import struct
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "fixtures/gyro_calib.jsonl"
GYRO = {"gx": 685, "gy": 885, "gz": 1085}
N = 100
KNOWN_DEG = 720.0  # 2 full turns


def samples(data, off):
    return list(struct.unpack_from(f"<{N}h", data, off))


def load():
    phases = {}
    for line in open(PATH):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("datalen") != 1917:
            continue
        data = bytes.fromhex(r["data_hex"])
        rec = {"wall": r["wall"]}
        for name, off in GYRO.items():
            rec[name] = samples(data, off)
        phases.setdefault(r["phase"], []).append(rec)
    return phases


def main():
    phases = load()
    print("phases:", {k: len(v) for k, v in phases.items()})

    # bias = mean of each gyro channel over the still phase
    bias = {}
    still = phases.get("still", [])
    for ch in GYRO:
        allv = [s for rec in still for s in rec[ch]]
        bias[ch] = sum(allv) / len(allv) if allv else 0.0
    print(f"\nstill bias (LSB): gx={bias['gx']:.1f} gy={bias['gy']:.1f} gz={bias['gz']:.1f}")
    if still:
        import statistics
        for ch in GYRO:
            allv = [s for rec in still for s in rec[ch]]
            print(f"  {ch} still std: {statistics.pstdev(allv):.1f} LSB")

    print(f"\n--- rotations (known {KNOWN_DEG:.0f} deg = 2 turns each) ---")
    Ks = []
    for ph in ["rotA", "rotB", "rotC"]:
        recs = phases.get(ph, [])
        if len(recs) < 2:
            print(f"{ph}: too few packets ({len(recs)})")
            continue
        n_pkt = len(recs)
        total_samples = n_pkt * N
        dur = recs[-1]["wall"] - recs[0]["wall"]
        # add one packet period so the last packet's samples are counted in duration
        pkt_period = dur / (n_pkt - 1) if n_pkt > 1 else 0.0
        dur_full = dur + pkt_period
        dt = dur_full / total_samples
        # per-channel bias-subtracted sum
        sums = {}
        for ch in GYRO:
            s = sum((v - bias[ch]) for rec in recs for v in rec[ch])
            sums[ch] = s
        dom = max(GYRO, key=lambda c: abs(sums[c]))
        integ = abs(sums[dom]) * dt  # LSB*s
        K = KNOWN_DEG / integ if integ else float("nan")
        fullscale = 32768 * K
        print(f"{ph}: pkts={n_pkt} dur={dur_full:.1f}s dt={dt*1000:.2f}ms/sample "
              f"dominant={dom} sum(raw-bias)={sums[dom]:.0f} "
              f"integ={integ:.0f}LSB*s -> K={K:.4f} deg/s/LSB  (full-scale +/-{fullscale:.0f} dps)")
        print(f"     channel sums: " + " ".join(f"{c}={sums[c]:.0f}" for c in GYRO))
        Ks.append((ph, dom, K))

    if len(Ks) >= 2:
        vals = [k for _, _, k in Ks]
        mean = sum(vals) / len(vals)
        spread = (max(vals) - min(vals)) / mean * 100 if mean else 0
        print(f"\nK across axes: {[f'{k:.4f}' for k in vals]}  mean={mean:.4f} deg/s/LSB  spread={spread:.1f}%")
        print(f"=> implied full-scale +/-{32768*mean:.0f} dps; openwhoop div-15 = K=0.0667 (+/-2185 dps)")
        print(f"=> 1/K = {1/mean:.2f} LSB per deg/s")


if __name__ == "__main__":
    main()
