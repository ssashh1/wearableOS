"""Read-only backfill diagnostic: is the strap stuck streaming raw, and does it
actually hold un-offloaded 24/7 history?

Does NOT change any mode and does NOT ack/trim. It:
  1. connects + bonds,
  2. listens ~8s WITHOUT asking for data — tallies frame types arriving unprompted
     (type-43 REALTIME_RAW_DATA arriving on its own => raw-collection mode is stuck ON),
  3. GET_DATA_RANGE (cmd 34) — prints raw + best-effort cursor decode,
  4. GET_CLOCK (cmd 11) — device clock now,
  5. GET_BATTERY for context.
"""
import asyncio
import struct
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

data_types = Counter()
data_notifs = 0
resp_q: asyncio.Queue = asyncio.Queue()


def data_cb(_, d):
    """Tally frame types arriving on the DATA char. Large frames fragment; the first
    fragment carries 0xAA + type byte at offset 4."""
    global data_notifs
    raw = bytes(d)
    data_notifs += 1
    if len(raw) >= 5 and raw[0] == 0xAA:
        t = raw[4]
        try:
            data_types[PacketType(t).name] += 1
        except ValueError:
            data_types[f"type{t}"] += 1
    else:
        data_types["(fragment/cont)"] += 1


def resp_cb(_, d):
    raw = bytes(d)
    try:
        pkt = WhoopPacket.from_data(raw)
        resp_q.put_nowait((pkt.cmd, pkt.data, raw))
    except Exception:
        resp_q.put_nowait((None, b"", raw))


async def send(client, cmd, payload=b"\x00", resp=True):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=resp)


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("strap not found — awake/nearby? app fully closed on the phone?")
        return
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}", flush=True)
        await client.start_notify(CMD_FROM, resp_cb)
        await client.start_notify(EVENTS, lambda _, d: None)
        await client.start_notify(DATA, data_cb)

        await send(client, CommandNumber.GET_BATTERY_LEVEL)
        await asyncio.sleep(1.5)
        print("(bonded)\n", flush=True)

        # 1) LISTEN ONLY — is the strap streaming data unprompted?
        print("=== listening 8s WITHOUT requesting data (unprompted stream?) ===", flush=True)
        data_types.clear()
        t0 = time.time()
        await asyncio.sleep(8)
        elapsed = time.time() - t0
        print(f"  DATA notifications in {elapsed:.0f}s: {data_notifs}", flush=True)
        print(f"  frame types: {dict(data_types)}", flush=True)
        print("  >>> type-43 REALTIME_RAW_DATA here = raw-collection mode is STUCK ON\n", flush=True)

        # 2) GET_DATA_RANGE
        print("=== GET_DATA_RANGE (cmd 34) ===", flush=True)
        while not resp_q.empty():
            resp_q.get_nowait()
        await send(client, CommandNumber.GET_DATA_RANGE)
        try:
            cmd, data, raw = await asyncio.wait_for(resp_q.get(), timeout=5)
            print(f"  raw: {raw.hex()}", flush=True)
            print(f"  data: {data.hex()}", flush=True)
            # best-effort: dump as a sequence of u32 LE (cursors are u32)
            body = data[2:] if len(data) > 2 else data
            u32s = [struct.unpack_from("<I", body, i)[0] for i in range(0, len(body) - 3, 4)]
            print(f"  u32 LE words: {u32s}", flush=True)
        except asyncio.TimeoutError:
            print("  no GET_DATA_RANGE response (timeout)", flush=True)

        # 3) GET_CLOCK
        print("\n=== GET_CLOCK (cmd 11) ===", flush=True)
        await send(client, CommandNumber.GET_CLOCK)
        try:
            cmd, data, raw = await asyncio.wait_for(resp_q.get(), timeout=5)
            print(f"  raw: {raw.hex()}", flush=True)
            if len(data) >= 6:
                dev_clock = struct.unpack_from("<I", data, 2)[0]
                print(f"  device clock now: {dev_clock}", flush=True)
        except asyncio.TimeoutError:
            print("  no GET_CLOCK response (timeout)", flush=True)

        print("\n=== done (no mode changed, no trim) ===", flush=True)


asyncio.run(main())
