#!/usr/bin/env python3
"""Generate the cross-language parity fixtures for the Swift WhoopProtocol library.

This is now a thin wrapper around `scripts/gen_synthetic_fixtures.py`, which produces the
6 Resources JSON files from SYNTHETIC, protocol-valid frames with NO dependency on any
private capture. The old behavior (reading gitignored `fixtures/*.jsonl|*.bin` real
captures) has been retired so the public repo is self-contained and provably synthetic.

Run with a venv that has whoop_protocol installed:
  python3 -m venv /tmp/whoop_venv
  /tmp/whoop_venv/bin/pip install -e server/packages/whoop-protocol
  /tmp/whoop_venv/bin/python scripts/gen_golden.py
"""
from gen_synthetic_fixtures import main

if __name__ == "__main__":
    main()
