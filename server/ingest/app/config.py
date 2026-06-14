"""Ingest service configuration from environment."""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    api_key: str
    db_dsn: str
    raw_root: str


def load_config() -> Config:
    api_key = os.environ.get("WHOOP_API_KEY")
    db_dsn = os.environ.get("WHOOP_DB_DSN")
    raw_root = os.environ.get("WHOOP_RAW_ROOT", "/data/raw")
    if not api_key:
        raise RuntimeError("WHOOP_API_KEY is required")
    if not db_dsn:
        raise RuntimeError("WHOOP_DB_DSN is required")
    return Config(api_key=api_key, db_dsn=db_dsn, raw_root=raw_root)
