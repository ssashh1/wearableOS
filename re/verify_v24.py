"""Verify the type-47 V24 biometric decode against the REAL on-device capture
fixtures/hist_biometric.bin (762 records pulled via the high-freq-sync handshake).

hist_biometric.bin = every char-05 DATA notification written verbatim, back-to-back.
BLE fragments are contiguous in the file, so a sequential length-walk reassembles frames.
Decode type-47 with openwhoop's V12/V24 layout (offsets into pkt.data) and check that
every field is physically plausible (HR ~57-70, |gravity|~1g, SpO2/skin-temp/resp in range).
"""
import struct, sys, zlib
from collections import Counter

sys.path.insert(0, "whoomp/scripts")
from packet import crc8  # noqa: E402

BIN = "fixtures/hist_biometric.bin"


def walk_frames(buf):
    """Sequentially reassemble frames: at each pos, trust a frame iff crc8(len) and
    crc32 both validate; else slip forward one byte."""
    i, n = 0, len(buf)
    while i + 4 < n:
        if buf[i] != 0xAA:
            i += 1
            continue
        length = struct.unpack_from("<H", buf, i + 1)[0]
        if length < 4 or i + length + 4 > n:
            i += 1
            continue
        if crc8(buf[i + 1:i + 3]) != buf[i + 3]:
            i += 1
            continue
        pkt = buf[i + 4:i + length]
        exp = struct.unpack_from("<L", buf, i + length)[0]
        if (zlib.crc32(pkt) & 0xFFFFFFFF) != exp:
            i += 1
            continue
        yield buf[i:i + length + 4], pkt  # full frame, inner [type,seq,cmd,data...]
        i += length + 4


def f32(d, o):
    return struct.unpack_from("<f", d, o)[0]


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def decode_v24(data):
    """data = pkt[3:] (the bytes after type,seq,cmd). openwhoop V12/V24 layout."""
    hr = data[14]
    rr_count = data[15]
    rr = [u16(data, 16 + 2 * i) for i in range(min(rr_count, 4))]
    rr = [x for x in rr if x]
    gx, gy, gz = f32(data, 33), f32(data, 37), f32(data, 41)
    return {
        "unix": struct.unpack_from("<L", data, 4)[0],
        "hr": hr, "rr_count": rr_count, "rr": rr,
        "ppg_green": u16(data, 26), "ppg_red_ir": u16(data, 28),
        "grav": (gx, gy, gz), "grav_mag": (gx * gx + gy * gy + gz * gz) ** 0.5,
        "skin_contact": data[48],
        "spo2_red": u16(data, 61), "spo2_ir": u16(data, 63),
        "skin_temp_raw": u16(data, 65), "ambient": u16(data, 67),
        "led1": u16(data, 69), "led2": u16(data, 71),
        "resp_raw": u16(data, 73), "sig_quality": u16(data, 75),
    }


def main():
    buf = open(BIN, "rb").read()
    types = Counter()
    versions = Counter()
    recs = []
    for full, pkt in walk_frames(buf):
        t = pkt[0]
        types[t] += 1
        if t == 47:  # HISTORICAL_DATA
            ver = pkt[1]
            versions[ver] += 1
            data = pkt[3:]
            if ver in (12, 24) and len(data) >= 77:
                recs.append(decode_v24(data))

    print(f"file: {len(buf)} bytes")
    print(f"frame types: {dict(types)}")
    print(f"type-47 versions (seq byte): {dict(versions)}")
    print(f"decoded V12/V24 records: {len(recs)}")
    if not recs:
        return
    hrs = [r["hr"] for r in recs if 0 < r["hr"] < 250]
    mags = [r["grav_mag"] for r in recs if r["grav_mag"] > 0]
    sk = [r["skin_temp_raw"] for r in recs]
    sr = [r["spo2_red"] for r in recs]
    si = [r["spo2_ir"] for r in recs]
    rp = [r["resp_raw"] for r in recs]
    contact = Counter(r["skin_contact"] for r in recs)

    def stats(xs):
        xs = sorted(xs)
        return f"min={xs[0]} med={xs[len(xs)//2]} max={xs[-1]} n={len(xs)}"

    print(f"\nHR        : {stats(hrs)}")
    print(f"grav_mag  : min={min(mags):.3f} med={sorted(mags)[len(mags)//2]:.3f} max={max(mags):.3f}")
    print(f"skin_temp : {stats(sk)}")
    print(f"spo2_red  : {stats(sr)}")
    print(f"spo2_ir   : {stats(si)}")
    print(f"resp_raw  : {stats(rp)}")
    print(f"skin_contact values: {dict(contact)}")
    rr_total = sum(len(r["rr"]) for r in recs)
    print(f"records with RR: {sum(1 for r in recs if r['rr'])}  total RR intervals: {rr_total}")

    print("\nfirst 5 records:")
    for r in recs[:5]:
        print(f"  unix={r['unix']} hr={r['hr']} rr={r['rr']} "
              f"grav=({r['grav'][0]:.2f},{r['grav'][1]:.2f},{r['grav'][2]:.2f}) |g|={r['grav_mag']:.3f} "
              f"skin_temp={r['skin_temp_raw']} spo2=({r['spo2_red']},{r['spo2_ir']}) "
              f"resp={r['resp_raw']} contact={r['skin_contact']}")


if __name__ == "__main__":
    main()
