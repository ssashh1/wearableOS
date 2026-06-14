"""Load + index the declarative decode schema."""
import json
import os
from functools import lru_cache

_SCHEMA_PATH = os.path.join(os.path.dirname(__file__), "schema", "whoop_protocol.json")


class Schema:
    def __init__(self, raw: dict):
        self._raw = raw
        self.enums = raw["enums"]
        self.envelope = raw["envelope"]
        self.packets = raw["packets"]
        # index packet spec by numeric type, honoring aliases
        self._by_type = {}
        for name, spec in self.packets.items():
            spec = {**spec, "name": name}
            self._by_type[spec["type"]] = spec
            for alias in spec.get("aliases", []):
                self._by_type[alias] = spec

    def enum_name(self, enum: str, value: int) -> str:
        # Suffixed "NAME(value)" form, matching the legacy whoop_fields `_name()`.
        # Used for event / resp_cmd / meta_type / cmd_name field values. For the bare
        # packet-type name (out["type_name"]) use type_name() instead.
        table = self.enums.get(enum, {})
        name = table.get(str(value))
        return f"{name}({value})" if name else f"0x{value:02X}({value})"

    def type_name(self, value: int) -> str:
        table = self.enums["PacketType"]
        return table.get(str(value), f"type{value}")

    def packet_for_type(self, value: int):
        return self._by_type.get(value)


@lru_cache(maxsize=1)
def load_schema() -> Schema:
    with open(_SCHEMA_PATH) as fh:
        return Schema(json.load(fh))
