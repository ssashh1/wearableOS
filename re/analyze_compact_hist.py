"""OFFLINE analysis of fixtures/historical_capture.bin (F0's full 104-chunk historical offload).
Goal: (a) is the type-43 raw genuinely historical or all live-session contamination?
      (b) characterize the COMPACT records (EVENT/etc.) that make up the strap's 14-day store.
Separates by timestamp; groups EVENTs by event number; dumps sample payloads per shape."""
import sys
import struct
from collections import Counter, defaultdict
import datetime

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType  # noqa: E402

BLOB = open("fixtures/historical_capture.bin", "rb").read()


def iter_valid(blob):
    i, n = 0, len(blob)
    while i + 8 <= n:
        if blob[i] != 0xAA:
            i += 1; continue
        length = int.from_bytes(blob[i + 1:i + 3], "little")
        end = i + length + 4
        if end > n or length < 8:
            i += 1; continue
        try:
            pkt = WhoopPacket.from_data(blob[i:end]); yield pkt; i = end
        except Exception:
            i += 1


def uni(v):
    if 1_600_000_000 < v < 1_800_000_000:
        return datetime.datetime.utcfromtimestamp(v).strftime("%Y-%m-%d %H:%M")
    return None


shapes = Counter()
type43_ts = []
events = defaultdict(list)     # event_num -> [(unix, payload_hex)]
console_n = 0

for pkt in iter_valid(BLOB):
    data = bytes(pkt.data)
    try:
        tn = PacketType(pkt.type).name
    except Exception:
        tn = f"type{pkt.type}"
    shapes[(tn, len(data))] += 1
    if pkt.type == PacketType.REALTIME_RAW_DATA.value and len(data) >= 8:
        type43_ts.append(struct.unpack_from("<I", data, 4)[0])
    elif pkt.type == PacketType.EVENT.value:
        evnum = pkt.cmd
        u = struct.unpack_from("<I", data, 1)[0] if len(data) >= 5 else 0
        events[evnum].append((u, data.hex()))
    elif pkt.type == PacketType.CONSOLE_LOGS.value:
        console_n += 1

print(f"total bytes {len(BLOB)}")
print("\n=== record shapes (type, payload_len) x count ===")
for s, n in shapes.most_common():
    print(f"  {s[0]:18} len={s[1]:5} x{n}")

if type43_ts:
    lo, hi = min(type43_ts), max(type43_ts)
    print(f"\n=== type-43 device-clock ts: n={len(type43_ts)} min={lo} max={hi} spread={hi-lo}s (~{(hi-lo)/3600:.1f}h) ===")
    print("  (narrow spread => all from one live session = contamination; wide => real historical)")

print(f"\n=== EVENT records by event number ({console_n} console logs total) ===")
for evnum, lst in sorted(events.items()):
    us = [u for u, _ in lst if 1_600_000_000 < u < 1_800_000_000]
    span = ""
    if us:
        span = f" unix {uni(min(us))}..{uni(max(us))}"
    print(f"  event #{evnum}: x{len(lst)}{span}")
    # show up to 3 distinct-length samples
    seen = set()
    for u, h in lst:
        L = len(h) // 2
        if L not in seen:
            seen.add(L)
            print(f"      len={L} unix={uni(u)} payload={h}")
