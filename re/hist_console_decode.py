"""READ-ONLY: offload a few history chunks WITHOUT acking (no trim), decode CONSOLE_LOGS to
text. The strap's firmware logs narrate sigproc / data-collection state and may name what drives
the persistent raw stream. Never acks -> never trims/erases."""
import asyncio
import sys
import time
from collections import Counter

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 12

databuf = bytearray()


def data_cb(_, d):
    databuf.extend(bytes(d))


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


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=20.0)
    if dev is None:
        print("strap not found"); return
    async with BleakClient(dev) as c:
        await c.start_notify(CMD_FROM, lambda _, d: None)
        await c.start_notify(EVENTS, lambda _, d: None)
        await c.start_notify(DATA, data_cb)
        pkt = WhoopPacket(PacketType.COMMAND, 10, CommandNumber.GET_BATTERY_LEVEL, data=b"\x00").framed_packet()
        await c.write_gatt_char(CMD_TO, pkt, response=True)
        await asyncio.sleep(1.5)
        databuf.clear()
        sh = WhoopPacket(PacketType.COMMAND, 10, CommandNumber.SEND_HISTORICAL_DATA, data=b"\x00").framed_packet()
        await c.write_gatt_char(CMD_TO, sh, response=False)
        print(f"capturing {SECS}s of history (no ack)...", flush=True)
        await asyncio.sleep(SECS)
        ab = WhoopPacket(PacketType.COMMAND, 10, CommandNumber.ABORT_HISTORICAL_TRANSMITS, data=b"\x00").framed_packet()
        await c.write_gatt_char(CMD_TO, ab, response=False)

    logs = []
    types = Counter()
    for f in split_frames(bytes(databuf)):
        length = int.from_bytes(f[1:3], "little")
        pkt = f[4:length]
        if not pkt:
            continue
        types[pkt[0]] += 1
        if pkt[0] == PacketType.CONSOLE_LOGS.value:
            body = pkt[3:]
            # strip 7-byte log header, drop the 34 00 01 marker, cut at NUL
            txt = body[7:]
            txt = txt.replace(b"\x34\x00\x01", b"")
            txt = txt.split(b"\x00")[0]
            s = txt.decode("utf-8", "replace").strip()
            if s:
                logs.append(s)
    print(f"\ncaptured {len(databuf)} bytes; frame-type counts {dict(types)}", flush=True)
    print(f"=== {len(logs)} console log lines ===", flush=True)
    seen = set()
    for s in logs:
        print("  " + s, flush=True)


asyncio.run(main())
