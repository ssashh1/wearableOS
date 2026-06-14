"""F0.a capture: drain the strap's historical buffer and SAVE THE RAW PAYLOAD BYTES.

Unlike hist_raw_test.py (which only wrote frames that parsed in a single BLE
notification — so it trimmed history while saving ~nothing for the large,
fragmented historical frames), this logs EVERY DATA-characteristic notification
verbatim. BLE preserves order on a characteristic, so the concatenation of all
notifications is exactly the frame stream (0xAA | u16 len | crc8 | pkt | crc32),
which scripts/gen_golden.py:_split_frames reassembles offline.

It still acks each HISTORY_END (= trim) to drain the whole buffer (user-approved),
but only AFTER the bytes for that chunk are already on disk (flushed). The noisy
per-fragment hex printing is gone (it was starving the event loop and likely
causing the mid-offload disconnect).

Re-running is safe: if the link drops, the strap resumes offloading whatever it
hasn't trimmed yet.
"""
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

OUT = "whoop_hist.bin"

meta_q: asyncio.Queue = asyncio.Queue()
total_bytes = 0
notif_count = 0
histf = open(OUT, "wb")


def data_cb(_, data):
    """Write EVERY notification verbatim (fast, silent). Parse only to surface
    the small single-notification METADATA frames the ack loop needs."""
    global total_bytes, notif_count
    raw = bytes(data)
    histf.write(raw)
    histf.flush()
    total_bytes += len(raw)
    notif_count += 1
    # Metadata frames are small and arrive whole; large historical frames fragment
    # and will raise here — that's fine, we already saved the bytes.
    try:
        pkt = WhoopPacket.from_data(raw)
    except Exception:
        return
    if pkt.type == PacketType.METADATA:
        meta_q.put_nowait(pkt)
        print(f"    META: {MetadataType(pkt.cmd)} {pkt.data.hex()}", flush=True)


async def send(client, cmd, payload=b"\x00", resp=False):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=resp)


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("not found — is the strap awake/nearby and NOT held by the iPhone app?")
        return
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}", flush=True)
        await client.start_notify(CMD_FROM, lambda _, d: print(f"  RESP: {WhoopPacket.from_data(bytes(d))}", flush=True))
        await client.start_notify(EVENTS, lambda _, d: None)
        await client.start_notify(DATA, data_cb)

        # Bond via confirmed write
        await send(client, CommandNumber.GET_BATTERY_LEVEL, resp=True)
        await asyncio.sleep(1.5)
        print("(bonded)\n", flush=True)

        # Ask the strap what range it holds (logged for F0.b context).
        await send(client, CommandNumber.GET_DATA_RANGE, resp=True)
        await asyncio.sleep(0.5)

        # === HISTORICAL OFFLOAD (capture + drain) ===
        print("=== HISTORICAL OFFLOAD ===", flush=True)
        t0 = time.time()
        await send(client, CommandNumber.SEND_HISTORICAL_DATA, b"\x00", resp=True)
        chunks = 0
        try:
            while True:
                metapkt = await asyncio.wait_for(meta_q.get(), timeout=25)
                mt = MetadataType(metapkt.cmd)
                if mt == MetadataType.HISTORY_COMPLETE:
                    print(">>> HISTORY_COMPLETE", flush=True)
                    break
                if mt == MetadataType.HISTORY_END:
                    unix, subsec, unk0, trim = struct.unpack("<LHLL", metapkt.data[:14])
                    # Bytes for this chunk are already flushed to disk; now ack (= trim).
                    await send(client, CommandNumber.HISTORICAL_DATA_RESULT,
                               struct.pack("<BLL", 1, trim, 0), resp=True)
                    chunks += 1
                    print(f"    chunk {chunks}: trim={trim} unix={unix} "
                          f"| {notif_count} notifs, {total_bytes} bytes, {time.time()-t0:.0f}s",
                          flush=True)
        except asyncio.TimeoutError:
            print(f">>> historical stalled after {chunks} chunks "
                  f"(re-run to resume the remaining buffer)", flush=True)
        print(f">>> DONE: {chunks} chunks acked, {notif_count} notifs, "
              f"{histf.tell()} bytes -> {OUT}, {time.time()-t0:.1f}s", flush=True)


asyncio.run(main())
