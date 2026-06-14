"""Quick authoritative battery read via standard BLE Battery Service."""
import asyncio
from bleak import BleakClient, BleakScanner

from device_config import DEVICE_UUID as ADDR
BATTERY = "00002a19-0000-1000-8000-00805f9b34fb"


async def main():
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("not found"); return
    async with BleakClient(dev) as c:
        for _ in range(3):
            v = await c.read_gatt_char(BATTERY)
            print(f"Standard battery (0x2A19): {int(v[0])}%")
            await asyncio.sleep(1)


asyncio.run(main())
