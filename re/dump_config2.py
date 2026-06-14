"""READ-ONLY clean enumeration v2 — fixes run-1 issues.

Run-1 learned: START_*_KEY_EXCHANGE(payload=01) returns `0a 01 01 <N u16 LE>` (N = entry
count: devcfg=1, FF=11). SEND_NEXT is a CURSOR (returns the next entry; my per-index payload
was wrong). Descriptor = `0a 01 01 00 01 <name\0>`. GET_*_VALUE by u8 index returned scrambled
status-0 buffers -> the value read almost certainly wants the key NAME (string), like SET.

This run: single START, cursor-style SEND_NEXT (payload 00) to collect ALL names, then GET each
value BY NAME. Still 100% read-only (no SET_* / nothing destructive).
"""
import asyncio
import json
import struct
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

LOG = open("re/config_dump.jsonl", "a", buffering=1)
resp_q: asyncio.Queue = asyncio.Queue()


def asc(b: bytes) -> str:
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b)


def cmd_from_cb(_, d):
    raw = bytes(d)
    try:
        pkt = WhoopPacket.from_data(raw)
        resp_q.put_nowait((pkt.cmd, bytes(pkt.data)))
    except Exception:
        resp_q.put_nowait((None, raw))


async def send(client, cmd, payload=b"\x00", resp=False):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=resp)


async def call(client, cmd, payload, label, wait=1.0):
    while not resp_q.empty():
        resp_q.get_nowait()
    await send(client, cmd, payload)
    await asyncio.sleep(wait)
    got = []
    while not resp_q.empty():
        got.append(resp_q.get_nowait())
    LOG.write(json.dumps({"ts": time.time(), "label": label, "cmd": cmd.value,
                          "payload": payload.hex(),
                          "resp": [(c, d.hex()) for c, d in got]}) + "\n")
    return got


def parse_name(data: bytes):
    """Descriptor `0a 01 01 00 01 <name\0...>` -> name, else None."""
    if len(data) >= 6 and data[1] == 0x01:
        body = data[5:]
        nul = body.find(b"\x00")
        name = body[:nul] if nul >= 0 else body
        if name and all(32 <= c < 127 for c in name):
            return name.decode()
    return None


async def enumerate_store(client, start_cmd, next_cmd, get_cmd, tag, max_iter=20):
    print(f"\n===== {tag} =====", flush=True)
    got = await call(client, start_cmd, b"\x01", f"{tag}.start")
    count = None
    for c, d in got:
        if len(d) >= 5 and d[1] == 0x01:
            count = struct.unpack_from("<H", d, 3)[0]
    print(f"  START -> count={count}  ({[(c, d.hex()) for c, d in got]})", flush=True)

    names = []
    empties = 0
    for i in range(max_iter):
        got = await call(client, next_cmd, b"\x00", f"{tag}.next#{i}", wait=0.7)
        found = None
        for c, d in got:
            nm = parse_name(d)
            if nm:
                found = nm
        if found:
            names.append(found)
            print(f"  [{len(names)}] {found}", flush=True)
            empties = 0
        else:
            empties += 1
            if empties >= 3 and len(names) > 0:
                break
            if empties >= 6:
                break
    print(f"  >>> {tag} names ({len(names)}): {names}", flush=True)

    print(f"  --- reading values BY NAME via {get_cmd.name} ---", flush=True)
    values = {}
    for nm in names:
        payload = nm.encode() + b"\x00"
        got = await call(client, get_cmd, payload, f"{tag}.getval[{nm}]", wait=0.8)
        for c, d in got:
            ok = d[1] if len(d) > 1 else None
            print(f"  {nm:26} status={ok} value={d.hex()}", flush=True)
            print(f"  {'':26} ascii={asc(d)}", flush=True)
            values[nm] = d.hex()
    return names, count, values


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=20.0)
    if dev is None:
        print("strap not found — app force-quit + phone BT off?", flush=True)
        return
    async with BleakClient(dev) as client:
        print(f"connected: {client.is_connected}", flush=True)
        await client.start_notify(CMD_FROM, cmd_from_cb)
        await client.start_notify(EVENTS, lambda _, d: None)
        await client.start_notify(DATA, lambda _, d: None)
        await send(client, CommandNumber.GET_BATTERY_LEVEL, b"\x00", resp=True)
        await asyncio.sleep(1.5)
        print("(bonded)", flush=True)

        await enumerate_store(client, CommandNumber.START_FF_KEY_EXCHANGE,
                              CommandNumber.SEND_NEXT_FF, CommandNumber.GET_FF_VALUE, "FF")
        await enumerate_store(client, CommandNumber.START_DEVICE_CONFIG_KEY_EXCHANGE,
                              CommandNumber.SEND_NEXT_DEVICE_CONFIG,
                              CommandNumber.GET_DEVICE_CONFIG_VALUE, "DEVCFG")

        print("\n===== RESEARCH PACKET (132) idx 0..4 =====", flush=True)
        for i in range(5):
            got = await call(client, CommandNumber.GET_RESEARCH_PACKET, struct.pack("<B", i),
                             f"research#{i}", wait=0.8)
            for c, d in got:
                print(f"  i={i}: {d.hex()}   ascii={asc(d)}", flush=True)

        print("\ndone", flush=True)


asyncio.run(main())
