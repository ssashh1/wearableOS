"""READ-ONLY: capture the strap's unsolicited CONSOLE_LOGS (type 50) for ~SECS seconds.
Strap firmware logs often name the active sigproc / data-collection mode in plaintext, which
may reveal what's driving the persistent type-43 raw stream. Pure listen — sends only the bond
write + GET_CLOCK; never changes any mode."""
import asyncio
import sys
import time

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 20

databuf = bytearray()
logs = []


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
        print(f"listening {SECS}s for console logs...", flush=True)
        await asyncio.sleep(SECS)

    for f in split_frames(bytes(databuf)):
        length = int.from_bytes(f[1:3], "little")
        pkt = f[4:length]
        if pkt and pkt[0] == PacketType.CONSOLE_LOGS.value:
            # whoomp: payload text starts after [type,seq,cmd] + 7 header bytes, minus trailing
            body = pkt[3:]
            txt = body[7:].split(b"\x00")[0]
            try:
                s = txt.decode("utf-8", "replace").strip()
            except Exception:
                s = repr(txt)
            if s:
                logs.append(s)
    print(f"\n=== {len(logs)} console log lines ===", flush=True)
    for s in logs:
        print("  " + s, flush=True)


asyncio.run(main())
