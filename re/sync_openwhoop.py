"""Gen4 history-sync handshake to pull the BIOMETRIC type-47 records
(HR/RR/SpO2/skin-temp/PPG) that a plain SEND_HISTORICAL_DATA never surfaced.

Gen4 high-frequency-sync command sequence (protocol facts, observed on-device):
  hello_harvard(35,[0x00]) -> set_time(10, unix u32 LE + 5 pad) -> get_name(76,[0x00])
  -> ENTER_HIGH_FREQ_SYNC(96, empty)  <-- the missing piece
  -> SEND_HISTORICAL_DATA(22,[0x00])
  -> loop: on METADATA HISTORY_END, ack HISTORICAL_DATA_RESULT(23) = [0x01]+end_data[8],
     where end_data = metadata.data[10:18] (unix u32, skip 6, then i(4)+j(4)).  <-- correct ack
  -> until HISTORY_COMPLETE.
Saves every DATA notification verbatim + tallies type-47 (HISTORICAL_DATA) biometric records.
This DOES trim (acks) — your history is server-backed + saved here. User-approved."""
import asyncio
import struct
import sys
import time
from collections import Counter

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber, MetadataType, crc8  # noqa: E402
import zlib  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
OUT = "fixtures/hist_biometric.bin"

meta_q: asyncio.Queue = asyncio.Queue()
histf = open(OUT, "wb")
total = 0
type47 = 0
notifs = 0


def data_cb(_, data):
    global total, type47, notifs
    raw = bytes(data)
    histf.write(raw); histf.flush()
    total += len(raw); notifs += 1
    try:
        pkt = WhoopPacket.from_data(raw)
    except Exception:
        return
    if pkt.type == PacketType.METADATA:
        meta_q.put_nowait(pkt)
        print(f"    META: {MetadataType(pkt.cmd)} data={pkt.data.hex()}", flush=True)
    elif pkt.type == PacketType.HISTORICAL_DATA:  # type 47 — the biometric record!
        type47 += 1


def frame(cmd_num, payload):
    pkt = struct.pack("<BBB", PacketType.COMMAND.value, 0, cmd_num) + payload
    blen = struct.pack("<H", len(pkt) + 4)
    return b"\xaa" + blen + struct.pack("<B", crc8(blen)) + pkt + struct.pack("<L", zlib.crc32(pkt) & 0xFFFFFFFF)


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=20.0)
    if dev is None:
        print("strap not found"); return
    async with BleakClient(dev) as c:
        await c.start_notify(CMD_FROM, lambda _, d: None)
        await c.start_notify(EVENTS, lambda _, d: None)
        await c.start_notify(DATA, data_cb)
        # bond
        await c.write_gatt_char(CMD_TO, frame(CommandNumber.GET_BATTERY_LEVEL.value, b"\x00"), response=True)
        await asyncio.sleep(1.5)
        print("(bonded)\n=== openwhoop Gen4 sync handshake ===", flush=True)

        now = int(time.time())
        seq = [
            ("hello_harvard", frame(CommandNumber.GET_HELLO_HARVARD.value, b"\x00")),
            ("set_time", frame(CommandNumber.SET_CLOCK.value, struct.pack("<I", now) + b"\x00\x00\x00\x00\x00")),
            ("get_name", frame(CommandNumber.GET_ADVERTISING_NAME_HARVARD.value, b"\x00")),
            ("enter_high_freq_sync", frame(CommandNumber.ENTER_HIGH_FREQ_SYNC.value, b"")),
            ("history_start", frame(CommandNumber.SEND_HISTORICAL_DATA.value, b"\x00")),
        ]
        for name, f in seq:
            await c.write_gatt_char(CMD_TO, f, response=False)
            print(f"  -> {name}", flush=True)
            await asyncio.sleep(0.4)

        chunks = 0
        t0 = time.time()
        try:
            while True:
                m = await asyncio.wait_for(meta_q.get(), timeout=25)
                mt = MetadataType(m.cmd)
                if mt == MetadataType.HISTORY_COMPLETE:
                    print(">>> HISTORY_COMPLETE", flush=True)
                    break
                if mt == MetadataType.HISTORY_END:
                    end_data = bytes(m.data[10:18])  # openwhoop: unix(4) skip(6) i(4) j(4)
                    ack = frame(CommandNumber.HISTORICAL_DATA_RESULT.value, b"\x01" + end_data)
                    await c.write_gatt_char(CMD_TO, ack, response=True)
                    chunks += 1
                    print(f"    chunk {chunks}: end_data={end_data.hex()} | type47={type47} total={total}B {time.time()-t0:.0f}s", flush=True)
        except asyncio.TimeoutError:
            print(f">>> stalled after {chunks} chunks", flush=True)
        print(f"\n=== DONE: {chunks} chunks, type47(biometric)={type47}, {total}B -> {OUT} ===", flush=True)


asyncio.run(main())
