"""Hunt for a STEP COUNT / activity field in WHOOP 4.0 type-47 V24 records.

Decode all V24 records from both bins, sort by unix, then for every UNMAPPED byte
offset extract u8/u16/u24/u32 candidates and analyze across time-ordered records:
  - monotonic-increasing (cumulative step counter, resets at day boundary)
  - correlation with motion (gravity-vector delta vs neighbors)
  - plausible magnitude

Reports only numbers. Bins stay local.
"""
import struct
import sys
from collections import Counter

sys.path.insert(0, "re")
from verify_v24 import walk_frames, decode_v24  # noqa: E402

BINS = [
    "fixtures/hist_biometric.bin",
    "fixtures/diag_trim.bin",
]

# Mapped byte ranges (half-open) into `data`. Anything not covered is "unmapped".
MAPPED = [
    (4, 8),    # unix u32
    (8, 10),   # subsec  -- task lists 8-10 as unmapped, but verify_v24 doc says subsec@8. treat as candidate anyway
    (12, 13),  # sensor_m
    (13, 14),  # sensor_n
    (14, 15),  # hr
    (15, 16),  # rr_count
    (16, 24),  # rr
    (24, 26),  # ppg_flags
    (26, 28),  # ppg_green
    (28, 30),  # ppg_red_ir
    (33, 45),  # gravity 3xf32
    (48, 49),  # skin_contact
    (61, 63),  # spo2_red
    (63, 65),  # spo2_ir
    (65, 67),  # skin_temp
    (67, 69),  # ambient
    (69, 71),  # led1
    (71, 73),  # led2
    (73, 75),  # resp
    (75, 77),  # signal_quality
]

# Offsets the task wants investigated explicitly.
UNMAPPED_RANGES = [(8, 10), (10, 12), (12, 14), (30, 33), (45, 48), (49, 61), (75, 93)]


def collect():
    recs = []
    raws = []
    minlen = 10**9
    for path in BINS:
        buf = open(path, "rb").read()
        for full, pkt in walk_frames(buf):
            if pkt[0] != 47:
                continue
            ver = pkt[1]
            if ver not in (12, 24):
                continue
            data = pkt[3:]
            if len(data) < 77:
                continue
            r = decode_v24(data)
            r["_data"] = bytes(data)
            recs.append(r)
            raws.append(bytes(data))
            minlen = min(minlen, len(data))
    recs.sort(key=lambda r: (r["unix"], r.get("_data")[8:10]))
    return recs, minlen


def motion_series(recs):
    """Per-record motion = L2 delta of gravity vector vs previous record."""
    m = [0.0]
    for i in range(1, len(recs)):
        a, b = recs[i]["grav"], recs[i - 1]["grav"]
        d = sum((a[k] - b[k]) ** 2 for k in range(3)) ** 0.5
        m.append(d)
    return m


def read_field(data, off, width):
    if off + width > len(data):
        return None
    if width == 1:
        return data[off]
    if width == 2:
        return struct.unpack_from("<H", data, off)[0]
    if width == 3:
        return data[off] | (data[off + 1] << 8) | (data[off + 2] << 16)
    if width == 4:
        return struct.unpack_from("<I", data, off)[0]


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return 0.0
    mx = sum(xs) / n
    my = sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx == 0 or vy == 0:
        return 0.0
    return cov / (vx * vy) ** 0.5


def analyze_field(recs, motion, off, width):
    vals = []
    idx = []
    for i, r in enumerate(recs):
        v = read_field(r["_data"], off, width)
        if v is None:
            continue
        vals.append(v)
        idx.append(i)
    if not vals:
        return None
    n = len(vals)
    distinct = len(set(vals))
    vmin, vmax = min(vals), max(vals)
    # monotonic (non-decreasing) run analysis, allowing resets
    inc = sum(1 for a, b in zip(vals, vals[1:]) if b > a)
    dec = sum(1 for a, b in zip(vals, vals[1:]) if b < a)
    eq = sum(1 for a, b in zip(vals, vals[1:]) if b == a)
    # correlation with motion (use absolute value & also first-difference of field)
    mot = [motion[i] for i in idx]
    corr_level = pearson([float(v) for v in vals], mot)
    diffs = [max(0, vals[k] - vals[k - 1]) for k in range(1, len(vals))]
    corr_delta = pearson(diffs, mot[1:]) if len(diffs) > 2 else 0.0
    return {
        "off": off, "w": width, "n": n, "distinct": distinct,
        "min": vmin, "max": vmax, "inc": inc, "dec": dec, "eq": eq,
        "corr_level": corr_level, "corr_delta": corr_delta,
        "vals": vals,
    }


def main():
    recs, minlen = collect()
    print(f"decoded V24 records: {len(recs)}  min data len: {minlen}")
    if not recs:
        return
    unixes = [r["unix"] for r in recs]
    print(f"unix span: {min(unixes)} .. {max(unixes)}  ({max(unixes)-min(unixes)}s)")
    # day boundaries present?
    days = Counter(u // 86400 for u in unixes)
    print(f"distinct UTC-days in data: {len(days)}  day-buckets: {dict(days)}")

    motion = motion_series(recs)
    msort = sorted(motion)
    print(f"motion(grav-delta): min={msort[0]:.4f} med={msort[len(msort)//2]:.4f} "
          f"p90={msort[int(len(msort)*0.9)]:.4f} max={msort[-1]:.4f}")

    # Which offsets fall in unmapped ranges. Test each byte position with multiple widths.
    print("\n=== per-offset analysis (unmapped regions) ===")
    print(f"{'off':>4} {'w':>2} {'distinct':>8} {'min':>8} {'max':>10} "
          f"{'inc':>5} {'dec':>5} {'eq':>5} {'cLvl':>6} {'cDel':>6}")
    candidates = []
    for (lo, hi) in UNMAPPED_RANGES:
        print(f"--- region {lo}:{hi} ---")
        for off in range(lo, min(hi, minlen)):
            for w in (1, 2, 3, 4):
                if off + w > hi:
                    # still allow widths that spill within region only
                    pass
                res = analyze_field(recs, motion, off, w)
                if res is None:
                    continue
                # skip all-constant fields for the printed summary unless w==1
                tag = ""
                # monotonic-ish: mostly increasing, few decreases (resets allowed)
                mono = res["inc"] > 0 and res["dec"] <= max(2, len(recs) // 200) and res["distinct"] > 5
                if mono:
                    tag += " MONO"
                if abs(res["corr_level"]) > 0.3:
                    tag += f" CORRlvl={res['corr_level']:.2f}"
                if abs(res["corr_delta"]) > 0.3:
                    tag += f" CORRdel={res['corr_delta']:.2f}"
                if res["distinct"] <= 1:
                    tag += " CONST"
                print(f"{off:>4} {w:>2} {res['distinct']:>8} {res['min']:>8} {res['max']:>10} "
                      f"{res['inc']:>5} {res['dec']:>5} {res['eq']:>5} "
                      f"{res['corr_level']:>6.2f} {res['corr_delta']:>6.2f}{tag}")
                if tag and "CONST" not in tag:
                    candidates.append(res)

    # Highlight strongest step-counter candidates
    print("\n=== STRONGEST CANDIDATES (monotonic and/or motion-correlated) ===")
    def score(r):
        mono_score = r["inc"] - 3 * r["dec"]
        return max(mono_score, abs(r["corr_level"]) * 1000, abs(r["corr_delta"]) * 1000)
    candidates.sort(key=score, reverse=True)
    for r in candidates[:15]:
        print(f"off={r['off']} w={r['w']} distinct={r['distinct']} range=[{r['min']},{r['max']}] "
              f"inc={r['inc']} dec={r['dec']} corr_lvl={r['corr_level']:.2f} corr_delta={r['corr_delta']:.2f}")

    # Detailed dump of the tail and 49-61 gap behavior for a moving stretch
    print("\n=== sample sequences (first 30 records) for key unmapped bytes ===")
    keybytes = list(range(8, 14)) + [30, 31, 32, 45, 46, 47] + list(range(49, 61)) + list(range(77, min(minlen, 93)))
    keybytes = [b for b in keybytes if b < minlen]
    hdr = "idx  unix       mot   hr  " + " ".join(f"b{b}" for b in keybytes)
    print(hdr)
    for i in range(min(30, len(recs))):
        d = recs[i]["_data"]
        bs = " ".join(f"{d[b]:3d}" for b in keybytes)
        print(f"{i:3d} {recs[i]['unix']} {motion[i]:5.2f} {recs[i]['hr']:3d}  {bs}")


if __name__ == "__main__":
    main()
