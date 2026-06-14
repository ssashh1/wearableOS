"""Phase-3 experiment: find the command that PERSISTENTLY stops the type-43 raw flood.

STOP_RAW_DATA(82) is already sent by the app on connect yet the strap auto-streams type-43
on every fresh connect -> a persistent collection flag is set. Test the candidate toggles
one at a time, measuring the type-43 rate in a 6s window after each. Stop as soon as the
flood ceases (so we identify the exact command and don't over-toggle).

Read-only-ish: it changes a data-collection MODE (the thing we WANT off) but does not trim.
"""
import asyncio
import time
import sys
from collections import Counter

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"

raw43 = 0


def data_cb(_, d):
    global raw43
    raw = bytes(d)
    if len(raw) >= 5 and raw[0] == 0xAA and raw[4] == PacketType.REALTIME_RAW_DATA.value:
        raw43 += 1


async def send(client, cmd, payload, resp=True):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=resp)


async def window(client, label, secs=6):
    """Observe type-43 frames for `secs`, return the count."""
    global raw43
    raw43 = 0
    await asyncio.sleep(secs)
    print(f"  [{label}] type-43 frames in {secs}s: {raw43}", flush=True)
    return raw43


# (CommandNumber, payload, human label) — ordered most→least likely persistent toggle
CANDIDATES = [
    (CommandNumber.STOP_RAW_DATA, b"\x01", "STOP_RAW_DATA(82) p=01  [known transient — baseline]"),
    (CommandNumber.TOGGLE_R7_DATA_COLLECTION, b"\x00", "TOGGLE_R7_DATA_COLLECTION(16) p=00"),
    (CommandNumber.TOGGLE_LABRADOR_DATA_GENERATION, b"\x00", "TOGGLE_LABRADOR_DATA_GENERATION(124) p=00"),
    (CommandNumber.TOGGLE_LABRADOR_RAW_SAVE, b"\x00", "TOGGLE_LABRADOR_RAW_SAVE(125) p=00"),
]


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("strap not found — app closed / phone BT off / strap awake?")
        return
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}", flush=True)
        await client.start_notify(CMD_FROM, lambda _, d: None)
        await client.start_notify(EVENTS, lambda _, d: None)
        await client.start_notify(DATA, data_cb)
        await send(client, CommandNumber.GET_BATTERY_LEVEL, b"\x00")
        await asyncio.sleep(1.5)
        print("(bonded)\n", flush=True)

        base = await window(client, "BASELINE (no command)")
        if base == 0:
            print("  no flood at baseline — strap not streaming raw right now; nothing to disable.", flush=True)
            return

        for cmd, payload, label in CANDIDATES:
            print(f"\n>>> sending {label}", flush=True)
            await send(client, cmd, payload)
            await asyncio.sleep(1.0)
            n = await window(client, f"after {cmd.name}")
            if n == 0:
                print(f"\n*** SUCCESS: {cmd.name} (payload {payload.hex()}) STOPPED the type-43 flood ***", flush=True)
                # confirm it stays off for another window
                n2 = await window(client, "confirm (still off?)", secs=6)
                if n2 == 0:
                    print(f"*** CONFIRMED persistent: {cmd.name} ***", flush=True)
                else:
                    print(f"  (resumed after {n2} — not fully persistent)", flush=True)
                return
        print("\n>>> none of the candidates stopped the flood — need more candidates", flush=True)


asyncio.run(main())
