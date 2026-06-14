"""Now that bonding works: test the historical offload + raw accel/gyro stream."""
import asyncio
import struct
import sys
import time

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber, MetadataType  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"

meta_q: asyncio.Queue = asyncio.Queue()
hist_count = 0
raw_count = 0
histf = open("whoop_hist.bin", "wb")
raw_samples = []


def data_cb(_, data):
    global hist_count, raw_count
    raw = bytes(data)
    try:
        pkt = WhoopPacket.from_data(raw)
        if pkt.type == PacketType.HISTORICAL_DATA:
            hist_count += 1
            histf.write(raw); histf.flush()
        elif pkt.type == PacketType.METADATA:
            meta_q.put_nowait(pkt)
            print(f"    META: {MetadataType(pkt.cmd)} {pkt.data.hex()}", flush=True)
        elif pkt.type == PacketType.REALTIME_RAW_DATA:
            raw_count += 1
            if raw_count <= 3:
                print(f"    RAW_DATA: {raw.hex()}", flush=True)
    except Exception as e:
        print(f"    data parse err: {e} raw={raw.hex()[:40]}", flush=True)


async def send(client, cmd, payload=b"\x00", resp=False):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=resp)


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("not found"); return
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}", flush=True)
        await client.start_notify(CMD_FROM, lambda _, d: print(f"  RESP: {WhoopPacket.from_data(bytes(d))}", flush=True))
        await client.start_notify(EVENTS, lambda _, d: None)
        await client.start_notify(DATA, data_cb)

        # Bond via confirmed write
        await send(client, CommandNumber.GET_BATTERY_LEVEL, resp=True)
        await asyncio.sleep(1.5)
        print("(bonded)\n", flush=True)

        # === HISTORICAL OFFLOAD ===
        print("=== HISTORICAL OFFLOAD ===", flush=True)
        t0 = time.time()
        await send(client, CommandNumber.SEND_HISTORICAL_DATA, b"\x00", resp=True)
        chunks = 0
        try:
            while True:
                metapkt = await asyncio.wait_for(meta_q.get(), timeout=20)
                mt = MetadataType(metapkt.cmd)
                if mt == MetadataType.HISTORY_COMPLETE:
                    print(">>> HISTORY_COMPLETE", flush=True)
                    break
                if mt == MetadataType.HISTORY_END:
                    unix, subsec, unk0, trim = struct.unpack("<LHLL", metapkt.data[:14])
                    await send(client, CommandNumber.HISTORICAL_DATA_RESULT,
                               struct.pack("<BLL", 1, trim, 0), resp=True)
                    chunks += 1
                    if chunks % 20 == 0:
                        print(f"    ...{chunks} chunks, {hist_count} hist packets, {time.time()-t0:.0f}s", flush=True)
        except asyncio.TimeoutError:
            print(f">>> historical stalled after {chunks} chunks", flush=True)
        print(f">>> HISTORICAL: {chunks} chunks acked, {hist_count} packets, "
              f"{histf.tell()} bytes, {time.time()-t0:.1f}s\n", flush=True)

        # === RAW ACCEL/GYRO ===
        print("=== RAW DATA STREAM (5s) ===", flush=True)
        await send(client, CommandNumber.START_RAW_DATA, b"\x01", resp=True)
        await asyncio.sleep(5)
        await send(client, CommandNumber.STOP_RAW_DATA, b"\x01", resp=True)
        print(f">>> RAW: {raw_count} packets received", flush=True)


asyncio.run(main())
