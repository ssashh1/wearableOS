"""Confirm the LIVE type-43 stream carries decodable HR (same header as the historical chunks).
Capture ~8s of DATA notifications, reassemble frames, decode the type-43 cmd=41 header HR
(payload offset 14 = bpm, per F0). If we see plausible bpm, the fix is "decode type-43 HR live."
"""
import asyncio
import struct
import sys

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"

buf = bytearray()


def data_cb(_, d):
    buf.extend(bytes(d))


def split_frames(blob):
    i, n = 0, len(blob)
    while i + 4 <= n:
        if blob[i] != 0xAA:
            i += 1; continue
        length = int.from_bytes(blob[i + 1:i + 3], "little")
        end = i + length + 4
        if end > n:
            break
        yield blob[i:end]; i = end


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("strap not found"); return
    async with BleakClient(dev) as client:
        await client.start_notify(CMD_FROM, lambda _, d: None)
        await client.start_notify(EVENTS, lambda _, d: None)
        await client.start_notify(DATA, data_cb)
        pkt = WhoopPacket(PacketType.COMMAND, 10, CommandNumber.GET_BATTERY_LEVEL, data=b"\x00").framed_packet()
        await client.write_gatt_char(CMD_TO, pkt, response=True)
        await asyncio.sleep(1.5)
        buf.clear()
        print("capturing 8s of live stream...", flush=True)
        await asyncio.sleep(8)

    frames = list(split_frames(bytes(buf)))
    hrs = []
    for f in frames:
        length = struct.unpack("<H", f[1:3])[0]
        pkt = f[4:length]
        if len(pkt) < 4 or pkt[0] != PacketType.REALTIME_RAW_DATA.value:
            continue
        data = pkt[3:]  # payload after type,seq,cmd
        if len(data) >= 16:
            heart = data[14]
            if 25 <= heart <= 220:
                hrs.append(heart)
    print(f"captured {len(buf)} bytes, {len(frames)} frames, {len(hrs)} type-43 records with plausible HR", flush=True)
    print(f"HR values: {hrs}", flush=True)


asyncio.run(main())
