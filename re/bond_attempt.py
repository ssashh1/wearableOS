"""Attempt to bond/pair the strap to the Mac, then test the custom channels.
Watch for a macOS Bluetooth pairing dialog and accept it.
"""
import asyncio
import sys
import time

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber, EventNumber  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"

t0 = time.time()
counts = {"cmd_from": 0, "events": 0, "data": 0}


def mk(name):
    def cb(_, data):
        counts[name] += 1
        try:
            pkt = WhoopPacket.from_data(bytes(data))
            print(f"[{time.time()-t0:5.1f}s] {name}: {pkt}", flush=True)
        except Exception as e:
            print(f"[{time.time()-t0:5.1f}s] {name} raw={bytes(data).hex()[:40]} ({e})", flush=True)
    return cb


async def send(client, cmd, payload=b"\x00", resp=False):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=resp)
    print(f">>> {cmd.name} {payload.hex()} (resp={resp})", flush=True)


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("not found"); return
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}", flush=True)

        # 1. Explicit pair attempt
        try:
            res = await client.pair()
            print(f"client.pair() returned: {res}", flush=True)
        except Exception as e:
            print(f"client.pair() raised: {type(e).__name__}: {e}", flush=True)

        await client.start_notify(CMD_FROM, mk("cmd_from"))
        await client.start_notify(EVENTS, mk("events"))
        await client.start_notify(DATA, mk("data"))

        # 2. Confirmed write (response=True) — forces ATT response; may trigger encryption/pairing
        print("\n--- confirmed write (may trigger pairing dialog) ---", flush=True)
        try:
            await send(client, CommandNumber.GET_BATTERY_LEVEL, resp=True)
        except Exception as e:
            print(f"confirmed write raised: {type(e).__name__}: {e}", flush=True)
        await asyncio.sleep(2)

        # 3. Full command test
        await send(client, CommandNumber.GET_HELLO_HARVARD); await asyncio.sleep(1)
        await send(client, CommandNumber.REPORT_VERSION_INFO); await asyncio.sleep(1)
        await send(client, CommandNumber.GET_CLOCK); await asyncio.sleep(1)
        print("\n--- realtime 5s ---", flush=True)
        await send(client, CommandNumber.TOGGLE_REALTIME_HR, b"\x01")
        await asyncio.sleep(5)
        await send(client, CommandNumber.TOGGLE_REALTIME_HR, b"\x00")

        print(f"\n=== counts: {counts} ===", flush=True)


asyncio.run(main())
