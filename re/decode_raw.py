"""Decode header (ts/HR/RR) and crack the accel/gyro array in REALTIME_RAW_DATA."""
import json
import struct
import sys

sys.path.insert(0, "whoomp/scripts")
from packet import PacketType  # noqa: E402


def reassemble(fragments):
    buf, need = b"", 0
    for f in fragments:
        if need == 0:
            if not f or f[0] != 0xAA or len(f) < 3:
                continue
            total = struct.unpack("<H", f[1:3])[0] + 4
            if len(f) >= total:
                yield f[:total]
            else:
                buf, need = f, total
        else:
            buf += f
            if len(buf) >= need:
                yield buf[:need]; buf, need = b"", 0


def frame_parts(frame):
    length = struct.unpack("<H", frame[1:3])[0]
    pkt = frame[4:length]
    return pkt[0], pkt[1], pkt[2], pkt[3:]  # type, seq, cmd, data


def decode_header(data):
    unix, subsec, unk, heart = struct.unpack("<LHLB", data[4:15])
    rrnum = data[15]
    rrs = list(struct.unpack("<HHHH", data[16:24]))[:rrnum]
    return unix, subsec, heart, rrnum, rrs


rows = [json.loads(l) for l in open("capture.jsonl")]


def frames_for(phase):
    frags = [bytes.fromhex(r["full_hex"]) for r in rows
             if r.get("phase") == phase and r.get("char") == "data" and r.get("full_hex")]
    return list(reassemble(frags))


# 1. Historical HR time series
print("=== HISTORICAL HR records (decoded header) ===")
hist = [f for f in frames_for("historical") if frame_parts(f)[0] == PacketType.REALTIME_RAW_DATA.value]
for f in hist[:5]:
    _, _, cmd, data = frame_parts(f)
    u, ss, hr, n, rr = decode_header(data)
    print(f"  ts={u} hr={hr} rrnum={n} rr={rr} datalen={len(data)}")
print(f"  ...{len(hist)} historical raw packets total")

# 2. Crack the array region of a live raw packet
print("\n=== RAW packet array structure (data[24:]) ===")
raw = [f for f in frames_for("raw") if frame_parts(f)[0] == PacketType.REALTIME_RAW_DATA.value]
_, _, cmd, data = frame_parts(raw[0])
u, ss, hr, n, rr = decode_header(data)
print(f"header: ts={u} hr={hr} rr={rr}  total datalen={len(data)}  array region={len(data)-24} bytes")
arr = data[24:]
print(f"\nfirst 48 bytes after header (hex): {arr[:48].hex()}")
# interpret as int16 LE
vals = struct.unpack(f"<{len(arr)//2}h", arr[:len(arr)//2*2])
print(f"\nas int16 LE, first 40 values:\n{vals[:40]}")
print(f"\nint16 count in array: {len(vals)}  (if 6 channels: {len(vals)/6:.1f} samples/channel)")
# look for possible sub-structure: print bytes 24..40 of full data
print(f"\nbytes [24:40] (possible array header): {data[24:40].hex()}")
# stats over the whole array to spot channel ranges (blocked layout test)
import statistics
n6 = len(vals) // 6
if n6:
    for ci in range(6):
        seg = vals[ci*n6:(ci+1)*n6]
        print(f"  blocked-ch{ci}: min={min(seg)} max={max(seg)} mean={statistics.mean(seg):.0f}")
