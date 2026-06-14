# Reverse-engineering history

Scripts and notes from decoding the WHOOP 4.0 BLE protocol. The authoritative reference is
`../FINDINGS.md`. Several scripts import third-party clones that are intentionally **not**
committed (see root `.gitignore`):

- `whoomp/` — github.com/jogolden/whoomp (firmware-extracted protocol; `scripts/packet.py`).
- `whoop-reader/` — provides the local Python venv (`whoop-reader/.venv`, with `whoop_protocol`
  installed editable) used to run these scripts and `scripts/gen_golden.py`.

Clone/recreate these locally to run the RE scripts; they are not needed to build the app.
