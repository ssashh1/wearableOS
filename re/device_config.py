"""Local device identity for the RE scripts.

The real values (your strap's macOS BLE UUID / Bluetooth MAC / serial) are
personal and must never be committed. They are resolved, in order, from:

  1. re/device_local.py   (gitignored; create it from device_local.example.py)
  2. the WHOOP_DEVICE_UUID / WHOOP_DEVICE_MAC / WHOOP_DEVICE_SERIAL env vars
  3. inert placeholders    (so the published tree carries no personal identifiers)

Scripts use `from device_config import DEVICE_UUID as ADDR`.
"""
import os

_PLACEHOLDER_UUID = "00000000-0000-0000-0000-000000000000"
_PLACEHOLDER_MAC = "00:00:00:00:00:00"
_PLACEHOLDER_SERIAL = "0000000000"

try:
    # gitignored; holds the real personal values for local runs
    from device_local import (  # type: ignore
        DEVICE_UUID,
        DEVICE_MAC,
        DEVICE_SERIAL,
    )
except ImportError:
    DEVICE_UUID = os.environ.get("WHOOP_DEVICE_UUID", _PLACEHOLDER_UUID)
    DEVICE_MAC = os.environ.get("WHOOP_DEVICE_MAC", _PLACEHOLDER_MAC)
    DEVICE_SERIAL = os.environ.get("WHOOP_DEVICE_SERIAL", _PLACEHOLDER_SERIAL)
