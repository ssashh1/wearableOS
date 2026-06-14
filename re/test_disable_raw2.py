"""Phase-3 experiment #2: disable the raw flood by INVERTING the known enable sequence.

RE history (re/PROJECT_MEMORY.md): raw streaming is enabled by
  ENABLE_OPTICAL_DATA(107)=1 + TOGGLE_IMU_MODE(106)=1 + START_RAW_DATA(81)=1.
So test the inverse: STOP_RAW_DATA(82)=1 + TOGGLE_IMU_MODE(106)=0 + ENABLE_OPTICAL_DATA(107)=0.
Then DISCONNECT + RECONNECT to check whether "off" persists across a fresh connect
(determines whether the app sends the disable once or on every connect).
"""
import asyncio
import sys

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


async def observe(label, secs=6):
    global raw43
    raw43 = 0
    await asyncio.sleep(secs)
    print(f"  [{label}] type-43 in {secs}s: {raw43}", flush=True)
    return raw43


async def connect():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        return None
    c = BleakClient(dev)
    await c.connect()
    await c.start_notify(CMD_FROM, lambda _, d: None)
    await c.start_notify(EVENTS, lambda _, d: None)
    await c.start_notify(DATA, data_cb)
    await send(c, CommandNumber.GET_BATTERY_LEVEL, b"\x00")
    await asyncio.sleep(1.5)
    return c


async def main():
    c = await connect()
    if c is None:
        print("strap not found"); return
    print("Connected #1 (bonded)\n", flush=True)
    await observe("BASELINE")

    print("\n>>> sending DISABLE: STOP_RAW_DATA(82)=01, TOGGLE_IMU_MODE(106)=00, ENABLE_OPTICAL_DATA(107)=00", flush=True)
    await send(c, CommandNumber.STOP_RAW_DATA, b"\x01");      await asyncio.sleep(0.4)
    await send(c, CommandNumber.TOGGLE_IMU_MODE, b"\x00");    await asyncio.sleep(0.4)
    await send(c, CommandNumber.ENABLE_OPTICAL_DATA, b"\x00"); await asyncio.sleep(1.0)
    after = await observe("after DISABLE")

    await c.disconnect()
    print("\n--- disconnected; reconnecting to test persistence ---\n", flush=True)
    await asyncio.sleep(3)
    c2 = await connect()
    if c2 is None:
        print("reconnect: strap not found (may be re-advertising) — rerun to check persistence"); return
    print("Connected #2 (fresh) (bonded)\n", flush=True)
    fresh = await observe("FRESH CONNECT (no disable sent)")
    await c2.disconnect()

    print("\n=== RESULT ===", flush=True)
    print(f"  baseline flood: yes; after disable: {after}; on fresh reconnect: {fresh}", flush=True)
    if after == 0 and fresh == 0:
        print("  >>> disable WORKS and PERSISTS across reconnect (app sends it once).", flush=True)
    elif after == 0 and fresh > 0:
        print("  >>> disable works but the strap RE-ENABLES on reconnect — app must send it on EVERY connect.", flush=True)
    else:
        print("  >>> disable did NOT stop the flood — wrong commands/payloads; need more investigation.", flush=True)


asyncio.run(main())
