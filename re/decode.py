"""Reassemble fragmented BLE packets from capture.jsonl and decode fields."""
import json
import struct
import sys
import zlib

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType  # noqa: E402


def reassemble(fragments):
    """Yield complete frames from a list of raw notification byte-strings."""
    buf = b""
    need = 0
    for f in fragments:
        if need == 0:
            if not f or f[0] != 0xAA:
                continue  # stray, skip
            if len(f) < 3:
                continue
            length = struct.unpack("<H", f[1:3])[0]
            total = length + 4
            if len(f) >= total:
                yield f[:total]
            else:
                buf = f
                need = total
        else:
            buf += f
            if len(buf) >= need:
                yield buf[:need]
                buf = b""
                need = 0


def parse_frame(frame):
    length = struct.unpack("<H", frame[1:3])[0]
    pkt = frame[4:length]
    crc_ok = zlib.crc32(pkt) & 0xFFFFFFFF == struct.unpack("<L", frame[length:length+4])[0]
    return pkt[0], pkt[1], pkt[2], pkt[3:], crc_ok  # type, seq, cmd, data, crc_ok


rows = [json.loads(l) for l in open("capture.jsonl")]
for phase in ("realtime_hr", "raw", "historical"):
    frags = [bytes.fromhex(r["full_hex"]) for r in rows
             if r.get("phase") == phase and r.get("char") == "data" and r.get("full_hex")]
    frames = list(reassemble(frags))
    print(f"\n===== {phase}: {len(frags)} fragments -> {len(frames)} complete frames =====")
    bytype = {}
    for fr in frames:
        try:
            t, seq, cmd, data, ok = parse_frame(fr)
            tname = PacketType(t).name if t in [e.value for e in PacketType] else f"type{t}"
            bytype.setdefault(tname, []).append((len(data), cmd, ok, data))
        except Exception as e:
            print("  parse err:", e)
    for tname, items in bytype.items():
        ok_count = sum(1 for i in items if i[2])
        print(f"  {tname}: {len(items)} frames, {ok_count} crc-ok, data sizes {sorted(set(i[0] for i in items))[:6]}")
        # show first crc-ok example's data head
        for sz, cmd, ok, data in items:
            if ok:
                print(f"      e.g. cmd={cmd} datalen={sz} head={data[:32].hex()}")
                break
