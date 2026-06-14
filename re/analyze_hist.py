"""F0.b workbench: reassemble whoop_hist.bin into frames and inventory them.

The capture (re/hist_capture.py) is a verbatim concatenation of every DATA-char
notification, which equals the original frame stream:
    0xAA | <u16 length> | crc8(length-bytes) | pkt[type,seq,cmd,payload] | crc32
where length = offset of the crc32 (frame total = length + 4), matching
scripts/gen_golden.py:_split_frames and packet.WhoopPacket.from_data.

Usage:
    python re/analyze_hist.py                # histogram + per-type summary
    python re/analyze_hist.py --dump 47 5    # hex-dump first 5 HISTORICAL_DATA payloads
"""
import sys
import struct
import zlib
from collections import Counter

sys.path.insert(0, "whoomp/scripts")
from packet import PacketType  # noqa: E402

BIN = "whoop_hist.bin"


def split_frames(blob):
    """Yield (offset, frame_bytes) walking the 0xAA/length envelope."""
    i = 0
    n = len(blob)
    while i + 4 <= n:
        if blob[i] != 0xAA:
            i += 1
            continue
        length = int.from_bytes(blob[i + 1:i + 3], "little")
        end = i + length + 4
        if end > n:
            break
        yield i, blob[i:end]
        i = end


def parse_envelope(frame):
    """Return dict with hdr_crc_ok, data_crc_ok, ptype, seq, cmd, payload, or None if malformed."""
    if len(frame) < 8 or frame[0] != 0xAA:
        return None
    length = struct.unpack("<H", frame[1:3])[0]
    hdr_crc_ok = (_crc8(frame[1:3]) == frame[3])
    pkt = frame[4:length]
    if length + 4 > len(frame) or len(pkt) < 3:
        return None
    expected = struct.unpack("<L", frame[length:length + 4])[0]
    data_crc_ok = ((zlib.crc32(pkt) & 0xFFFFFFFF) == expected)
    return {
        "length": length,
        "hdr_crc_ok": hdr_crc_ok,
        "data_crc_ok": data_crc_ok,
        "ptype": pkt[0],
        "seq": pkt[1],
        "cmd": pkt[2],
        "payload": pkt[3:],   # bytes after [type, seq, cmd]
    }


# crc8 (same table source as packet.py)
from packet import crc8 as _crc8  # noqa: E402


def type_name(t):
    try:
        return PacketType(t).name
    except ValueError:
        return f"UNKNOWN({t})"


def main():
    blob = open(BIN, "rb").read()
    print(f"file: {BIN}  ({len(blob)} bytes)\n")
    frames = list(split_frames(blob))
    print(f"reassembled {len(frames)} frames\n")

    by_type = Counter()
    crc_bad = Counter()
    payload_lens = {}     # type -> Counter(payload_len)
    leftover = 0
    last_end = 0
    examples = {}         # type -> first parsed envelope
    for off, frame in frames:
        leftover += off - last_end
        last_end = off + len(frame)
        env = parse_envelope(frame)
        if env is None:
            by_type["MALFORMED"] += 1
            continue
        tn = type_name(env["ptype"])
        by_type[tn] += 1
        if not env["data_crc_ok"]:
            crc_bad[tn] += 1
        payload_lens.setdefault(tn, Counter())[len(env["payload"])] += 1
        examples.setdefault(tn, (off, env))

    print("=== frame-type histogram ===")
    for tn, c in by_type.most_common():
        bad = crc_bad.get(tn, 0)
        lens = payload_lens.get(tn, Counter())
        lensum = ", ".join(f"len={L}×{n}" for L, n in lens.most_common(6))
        print(f"  {tn:24s} {c:5d}  crc_bad={bad:<4d} payload[{lensum}]")
    print(f"\n  bytes between frames (should be 0): {leftover}")
    print(f"  trailing bytes after last frame: {len(blob) - last_end}")

    if len(sys.argv) >= 3 and sys.argv[1] == "--dump":
        want = int(sys.argv[2])
        count = int(sys.argv[3]) if len(sys.argv) >= 4 else 3
        print(f"\n=== first {count} payloads of type {want} ({type_name(want)}) ===")
        shown = 0
        for off, frame in frames:
            env = parse_envelope(frame)
            if env is None or env["ptype"] != want:
                continue
            p = env["payload"]
            print(f"\n[{shown}] off={off} seq={env['seq']} cmd={env['cmd']} "
                  f"payload_len={len(p)} data_crc_ok={env['data_crc_ok']}")
            # 16 bytes/row with offsets
            for r in range(0, len(p), 16):
                row = p[r:r + 16]
                hexs = " ".join(f"{b:02x}" for b in row)
                print(f"    {r:4d}: {hexs}")
            shown += 1
            if shown >= count:
                break


if __name__ == "__main__":
    main()
