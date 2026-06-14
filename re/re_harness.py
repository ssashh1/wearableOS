"""Persistent reverse-engineering harness for the Whoop 4.0.

Goals:
  - STAY connected (hold the BLE link, auto-reconnect on drop) so the strap
    isn't sitting in pairing/advertising mode.
  - Log EVERY notification losslessly (raw hex + whoomp-parsed) to JSONL.
  - Drive commands without dropping the link, via a control file:
        echo history   >> control.txt   # run historical offload + ack loop
        echo startreal  >> control.txt   # toggle realtime HR on
        echo stopreal   >> control.txt
        echo startraw   >> control.txt   # raw accel/gyro stream
        echo stopraw    >> control.txt
        echo version    >> control.txt
        echo battery    >> control.txt
        echo clock       >> control.txt
        echo hello       >> control.txt  # GET_HELLO_HARVARD handshake
        echo imu_on      >> control.txt  # TOGGLE_IMU_MODE
        echo raw:aa..    >> control.txt  # send an arbitrary framed hex packet
        echo quit        >> control.txt

Each control line is consumed (file truncated) after dispatch.
"""
import asyncio
import json
import struct
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, "whoomp/scripts")
from packet import WhoopPacket, PacketType, CommandNumber, MetadataType, EventNumber  # noqa: E402
from bleak import BleakClient, BleakScanner  # noqa: E402

from device_config import DEVICE_UUID as ADDR
CMD_TO = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CMD_FROM = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
EVENTS = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
DATA = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
MEMFAULT = "61080007-8d6d-82b8-614a-1c8cb0f8dcc6"
HR_STD = "00002a37-0000-1000-8000-00805f9b34fb"

CHAR_NAMES = {
    CMD_FROM: "cmd_from", EVENTS: "events", DATA: "data",
    MEMFAULT: "memfault", HR_STD: "hr_std",
}

LOG_PATH = "re_log.jsonl"
HIST_BIN = "whoop_hist.bin"
CONTROL = "control.txt"

logf = open(LOG_PATH, "a", buffering=1)
histf = open(HIST_BIN, "ab")
meta_q: asyncio.Queue = asyncio.Queue()
running = True
wrist_state = "unknown"
charge_state = "unknown"


def now():
    return datetime.now(timezone.utc).isoformat()


def log(char_name, raw: bytes, parsed=None, note=None):
    rec = {"ts": now(), "char": char_name, "len": len(raw), "hex": raw.hex()}
    if parsed is not None:
        rec["parsed"] = str(parsed)
    if note:
        rec["note"] = note
    logf.write(json.dumps(rec) + "\n")


def parse_std_hr(data: bytearray):
    flags = data[0]
    idx = 1
    if flags & 0x01:
        hr = int.from_bytes(data[idx:idx+2], "little"); idx += 2
    else:
        hr = data[idx]; idx += 1
    rrs = []
    if (flags >> 4) & 0x01:
        while idx + 2 <= len(data):
            rrs.append(round(int.from_bytes(data[idx:idx+2], "little")/1024*1000, 1))
            idx += 2
    return f"HR={hr} RR={rrs}"


def make_whoop_handler(char_name):
    def handler(_, data):
        global wrist_state, charge_state
        raw = bytes(data)
        try:
            pkt = WhoopPacket.from_data(raw)
            parsed = pkt
            # Track wrist/charge state from events
            if pkt.type == PacketType.EVENT:
                try:
                    ev = EventNumber(pkt.cmd)
                    if ev == EventNumber.WRIST_ON: wrist_state = "on"
                    elif ev == EventNumber.WRIST_OFF: wrist_state = "off"
                    elif ev == EventNumber.CHARGING_ON: charge_state = "charging"
                    elif ev == EventNumber.CHARGING_OFF: charge_state = "not_charging"
                except ValueError:
                    pass
            # Route historical + metadata
            if pkt.type == PacketType.HISTORICAL_DATA:
                histf.write(raw); histf.flush()
            if pkt.type == PacketType.METADATA:
                meta_q.put_nowait(pkt)
            log(char_name, raw, parsed)
            # Echo interesting things to stdout
            if pkt.type in (PacketType.REALTIME_DATA, PacketType.REALTIME_RAW_DATA,
                            PacketType.EVENT, PacketType.METADATA,
                            PacketType.COMMAND_RESPONSE, PacketType.CONSOLE_LOGS):
                print(f"[{time.strftime('%H:%M:%S')}] {char_name}: {pkt}", flush=True)
        except Exception as e:
            log(char_name, raw, note=f"unparsed: {e}")
    return handler


def std_hr_handler(_, data):
    raw = bytes(data)
    log("hr_std", raw, parse_std_hr(bytearray(data)))


async def send(client, cmd, payload=b"\x00"):
    pkt = WhoopPacket(PacketType.COMMAND, 10, cmd, data=payload).framed_packet()
    await client.write_gatt_char(CMD_TO, pkt, response=False)
    print(f">>> sent {cmd.name} payload={payload.hex()}", flush=True)
    log("cmd_to", pkt, note=f"sent {cmd.name}")


async def run_historical(client):
    """Replicate whoomp's historical offload ack-loop."""
    print(">>> starting historical offload...", flush=True)
    # drain stale metadata
    while not meta_q.empty():
        meta_q.get_nowait()
    await send(client, CommandNumber.SEND_HISTORICAL_DATA, b"\x00")
    chunks = 0
    try:
        while True:
            metapkt = await asyncio.wait_for(meta_q.get(), timeout=30)
            mt = MetadataType(metapkt.cmd)
            print(f"    meta: {mt} {metapkt.data.hex()}", flush=True)
            if mt == MetadataType.HISTORY_COMPLETE:
                print(">>> HISTORY_COMPLETE", flush=True)
                break
            if mt == MetadataType.HISTORY_END:
                unix, subsec, unk0, trim = struct.unpack("<LHLL", metapkt.data[:14])
                ack = struct.pack("<BLL", 1, trim, 0)
                await send(client, CommandNumber.HISTORICAL_DATA_RESULT, ack)
                chunks += 1
    except asyncio.TimeoutError:
        print(f">>> historical timed out after {chunks} chunks (no more metadata)", flush=True)
    print(f">>> historical done, {chunks} chunks acked", flush=True)


async def control_loop(client):
    global running
    import os
    open(CONTROL, "a").close()
    while running:
        try:
            with open(CONTROL) as f:
                lines = [ln.strip() for ln in f if ln.strip()]
            if lines:
                open(CONTROL, "w").close()  # consume
            for cmd in lines:
                print(f"### control: {cmd}", flush=True)
                if cmd == "quit":
                    running = False
                elif cmd == "hello":
                    await send(client, CommandNumber.GET_HELLO_HARVARD)
                elif cmd == "linkvalid":
                    await send(client, CommandNumber.LINK_VALID)
                elif cmd == "version":
                    await send(client, CommandNumber.REPORT_VERSION_INFO)
                elif cmd == "battery":
                    await send(client, CommandNumber.GET_BATTERY_LEVEL)
                elif cmd == "clock":
                    await send(client, CommandNumber.GET_CLOCK)
                elif cmd == "startreal":
                    await send(client, CommandNumber.TOGGLE_REALTIME_HR, b"\x01")
                elif cmd == "stopreal":
                    await send(client, CommandNumber.TOGGLE_REALTIME_HR, b"\x00")
                elif cmd == "startraw":
                    await send(client, CommandNumber.START_RAW_DATA, b"\x01")
                elif cmd == "stopraw":
                    await send(client, CommandNumber.STOP_RAW_DATA, b"\x01")
                elif cmd == "imu_on":
                    await send(client, CommandNumber.TOGGLE_IMU_MODE, b"\x01")
                elif cmd == "imu_off":
                    await send(client, CommandNumber.TOGGLE_IMU_MODE, b"\x00")
                elif cmd == "abort":
                    await send(client, CommandNumber.ABORT_HISTORICAL_TRANSMITS)
                elif cmd == "history":
                    await run_historical(client)
                elif cmd.startswith("raw:"):
                    frame = bytes.fromhex(cmd[4:])
                    await client.write_gatt_char(CMD_TO, frame, response=False)
                    log("cmd_to", frame, note="raw control frame")
                else:
                    print(f"### unknown control: {cmd}", flush=True)
        except Exception as e:
            print(f"control error: {e}", flush=True)
        await asyncio.sleep(0.5)


async def hold_connection():
    global running
    disconnected = asyncio.Event()

    def on_disc(_):
        print("!!! disconnected", flush=True)
        disconnected.set()

    while running:
        disconnected.clear()
        dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
        if dev is None:
            print("device not found, retrying in 5s...", flush=True)
            await asyncio.sleep(5)
            continue
        try:
            async with BleakClient(dev, disconnected_callback=on_disc) as client:
                print(f"=== CONNECTED to {dev.name} at {now()} ===", flush=True)
                for uuid, name in CHAR_NAMES.items():
                    try:
                        h = std_hr_handler if uuid == HR_STD else make_whoop_handler(name)
                        await client.start_notify(uuid, h)
                    except Exception as e:
                        print(f"subscribe {name} failed: {e}", flush=True)
                # handshake to wake the command/data channels
                await send(client, CommandNumber.GET_HELLO_HARVARD)
                await asyncio.sleep(0.3)
                await send(client, CommandNumber.REPORT_VERSION_INFO)
                ctrl = asyncio.create_task(control_loop(client))
                # keepalive: poll clock every 25s; exit if disconnected
                while running and not disconnected.is_set():
                    try:
                        await asyncio.wait_for(disconnected.wait(), timeout=25)
                    except asyncio.TimeoutError:
                        try:
                            await send(client, CommandNumber.GET_CLOCK)
                        except Exception:
                            break
                ctrl.cancel()
        except Exception as e:
            print(f"connection error: {e}", flush=True)
        if running:
            print("reconnecting in 3s...", flush=True)
            await asyncio.sleep(3)
    print("harness stopped.", flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(hold_connection())
    except KeyboardInterrupt:
        running = False
        print("interrupted", flush=True)
