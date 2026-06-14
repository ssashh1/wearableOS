"""F0.b: decode HR/R-R from the historical type-43 frames + characterize substructure.

Historical payload is REALTIME_RAW_DATA (type 43). Per re/decode_raw.py the header is:
    data[4:8]   unix  (u32, device clock)
    data[8:10]  subsec(u16)
    data[10:14] unk   (u32)
    data[14]    heart (u8)
    data[15]    rrnum (u8)
    data[16:..] rr    (rrnum * u16)
data[0:4] is a 4-byte sub-header (constant-ish 'ca 28 ..'); cmd byte may distinguish
header-bearing frames from IMU/optical continuations.
"""
import struct
import sys
from collections import Counter

sys.path.insert(0, "whoomp/scripts")
from packet import PacketType  # noqa: E402

BIN = "fixtures/historical_capture.bin"
RAW = PacketType.REALTIME_RAW_DATA.value  # 43


def split_frames(blob):
    i, n = 0, len(blob)
    while i + 4 <= n:
        if blob[i] != 0xAA:
            i += 1
            continue
        length = int.from_bytes(blob[i + 1:i + 3], "little")
        end = i + length + 4
        if end > n:
            break
        yield blob[i:end]
        i = end


def parts(frame):
    length = struct.unpack("<H", frame[1:3])[0]
    pkt = frame[4:length]
    return pkt[0], pkt[1], pkt[2], pkt[3:]  # type, seq, cmd, data


blob = open(BIN, "rb").read()
raw_frames = [parts(f) for f in split_frames(blob) if len(f) >= 8 and parts(f)[0] == RAW]
print(f"type-43 frames: {len(raw_frames)}")

# cmd-byte (subtype) histogram + payload-len per cmd
by_cmd = Counter()
len_by_cmd = {}
for _, seq, cmd, data in raw_frames:
    by_cmd[cmd] += 1
    len_by_cmd.setdefault(cmd, Counter())[len(data)] += 1
print("\n=== type-43 cmd/subtype histogram ===")
for cmd, c in by_cmd.most_common():
    lens = ", ".join(f"{L}×{n}" for L, n in len_by_cmd[cmd].most_common(4))
    print(f"  cmd={cmd:3d}: {c:4d} frames  datalen[{lens}]")

# Decode header on every frame; keep plausible HR
print("\n=== HR/R-R timeseries (plausible header rows) ===")
hr_rows = []
for _, seq, cmd, data in raw_frames:
    if len(data) < 16:
        continue
    unix, subsec, unk, heart = struct.unpack("<LHLB", data[4:15])
    rrnum = data[15]
    if 25 <= heart <= 220 and rrnum <= 4 and len(data) >= 16 + 2 * rrnum:
        rrs = list(struct.unpack(f"<{rrnum}H", data[16:16 + 2 * rrnum])) if rrnum else []
        hr_rows.append((unix, subsec, cmd, heart, rrnum, rrs))

print(f"plausible-HR frames: {len(hr_rows)} / {len(raw_frames)}")
if hr_rows:
    hrs = [r[3] for r in hr_rows]
    units = sorted(set(r[0] for r in hr_rows))
    print(f"HR: min={min(hrs)} max={max(hrs)} mean={sum(hrs)/len(hrs):.0f}")
    print(f"device-clock unix span: {units[0]} .. {units[-1]}  ({units[-1]-units[0]} ticks, {len(units)} distinct)")
    rr_total = sum(r[4] for r in hr_rows)
    print(f"total R-R intervals: {rr_total}")
    print("\nfirst 12 rows (unix, subsec, cmd, hr, rrnum, rrs):")
    for r in hr_rows[:12]:
        print(f"  unix={r[0]} ss={r[1]} cmd={r[2]} hr={r[3]} rrnum={r[4]} rrs={r[5]}")
    print("...last 6 rows:")
    for r in hr_rows[-6:]:
        print(f"  unix={r[0]} ss={r[1]} cmd={r[2]} hr={r[3]} rrnum={r[4]} rrs={r[5]}")
