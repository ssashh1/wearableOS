"""Enumerate the full GATT table of the Whoop strap to see what it actually exposes."""
import asyncio
from bleak import BleakClient, BleakScanner

from device_config import DEVICE_UUID as ADDR


async def main():
    print("Scanning to get device handle...")
    dev = await BleakScanner.find_device_by_address(ADDR, timeout=15.0)
    if dev is None:
        print("Device not found in scan. Is it awake/in range?")
        return
    print(f"Found: {dev.name} ({dev.address})")
    print("Connecting...")
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}\n")
        print("=== GATT SERVICES & CHARACTERISTICS ===")
        for service in client.services:
            print(f"\n[Service] {service.uuid}  ({service.description})")
            for char in service.characteristics:
                props = ",".join(char.properties)
                print(f"  [Char] {char.uuid}  props=({props})  ({char.description})")
                for desc in char.descriptors:
                    print(f"    [Desc] {desc.uuid}")


asyncio.run(main())
