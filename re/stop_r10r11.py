"""TEST: stop the type-43 REALTIME_RAW_DATA flood via SEND_R10_R11_REALTIME(63) payload [0x00]=OFF.
Observed for interoperability: cmd 63 toggles the R10/R11 realtime stream, payload
{1}=ON / {0}=OFF. The firmware console names the type-43 raw "R10+R11" — and every prior stop attempt
used STOP_RAW_DATA(82), a DIFFERENT mechanism. cmd 63 was never tried. Read-only except the one cmd.

Tally type-43 before, send 63[0x00], tally after. If the flood stops -> the lever is found.
"""
import asyncio, struct, sys, time
from collections import Counter
sys.path.insert(0, "whoomp/scripts")
from packet import crc8  # noqa
import zlib  # noqa
from bleak import BleakClient, BleakScanner  # noqa

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"

counts = Counter()
buf, need = b"", 0


def handle(frame):
    if len(frame) > 4:
        counts[frame[4]] += 1


def data_cb(_, d):
    global buf, need
    f = bytes(d)
    if need == 0:
        if f and f[0] == 0xAA and len(f) >= 3:
            total = struct.unpack("<H", f[1:3])[0] + 4
            if len(f) >= total:
                handle(f[:total])
            else:
                buf, need = f, total
    else:
        buf += f
        if len(buf) >= need:
            handle(buf[:need]); buf, need = b"", 0


def frame_cmd(cmd, payload=b"\x00"):
    inner = struct.pack("<BBB", 35, 0, cmd) + payload  # type=COMMAND(35), seq, cmd
    blen = struct.pack("<H", len(inner) + 4)
    return b"\xaa" + blen + struct.pack("<B", crc8(blen)) + inner + struct.pack("<L", zlib.crc32(inner) & 0xFFFFFFFF)


async def tally(label, secs):
    counts.clear()
    await asyncio.sleep(secs)
    t43 = counts.get(43, 0)
    print(f"  [{label}] over {secs}s: types={dict(counts)}  type-43={t43} ({t43/secs:.1f}/s)", flush=True)
    return t43


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=20.0)
    if dev is None:
        print("strap not found — phone BT off + app quit?"); return
    async with BleakClient(dev) as c:
        await c.start_notify(DATA, data_cb)
        await c.write_gatt_char(CMD_TO, frame_cmd(26, b"\x00"), response=True)  # GET_BATTERY = bond
        await asyncio.sleep(1.5)
        print("connected+bonded", flush=True)

        before = await tally("BEFORE", 10)
        print(">>> sending SEND_R10_R11_REALTIME(63) payload [0x00] = OFF", flush=True)
        await c.write_gatt_char(CMD_TO, frame_cmd(63, b"\x00"), response=True)
        await asyncio.sleep(1.0)
        after = await tally("AFTER 63[00]", 15)

        print(f"\n  RESULT: before={before/10:.1f}/s  after={after/15:.1f}/s  "
              f"{'FLOOD STOPPED ✅✅✅' if after == 0 else 'reduced' if after < before*0.5 else 'no change'}", flush=True)
        if after == 0:
            print("  -> cmd 63 [0x00] stops the R10/R11 flood. Next: test persistence across reboot,", flush=True)
            print("     and wire it into the app's connect sequence (replace/augment STOP_RAW).", flush=True)
        await c.disconnect()


asyncio.run(main())
