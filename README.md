# Wearable

Open-source, local-first client for a **WHOOP 4.0** band: read **your own** biometrics from
**your own** device over Bluetooth LE and keep the data on hardware you control. A native iOS app
(collect → decode → store → sync) backed by an optional self-hosted server. Decoding is
schema-driven (`protocol/whoop_protocol.json`) and shared by the phone and the server so they
never drift.

> **Disclaimer.** This is an independent, unofficial project. It is **not affiliated with,
> endorsed by, or sponsored by WHOOP, Inc.** "WHOOP" is a trademark of its respective owner and
> is used here only descriptively, to identify the hardware this software interoperates with.
> The project is the result of independent reverse-engineering for interoperability and is
> provided **for personal and educational use** with **your own device and your own data**, at
> your own risk. No warranty of any kind.
>
> **Not a medical device.** Heart rate, HRV, recovery, strain, sleep, SpO₂, and related
> outputs are approximations from published methods, are **not** clinically validated, and are
> **not medical advice**. Do not use them for diagnosis or treatment.
>
> **No proprietary material.** This repository contains **only original, independently written
> code** and factual protocol notes. Protocol facts were established by observing Bluetooth
> traffic to and from a device the author owns and, where needed for interoperability, by
> examining the official app — an activity permitted under 17 U.S.C. §1201(f). **None** of that
> material is reproduced here: the repository does **not** contain, redistribute, or link to any
> WHOOP, Inc. software, firmware, app binaries, decompiled source, artwork, logos, or other
> copyrighted or trademarked assets. It does not circumvent any access control, DRM, or
> account/paywall, and requires the user's own physical device and their own data.
>
> **Purpose: interoperability & research.** The work exists to let an owner read **their own
> device's data** in an interoperable way and for security-research and educational purposes —
> protected interests under interoperability and good-faith research principles (e.g. 17 U.S.C.
> §1201(f) reverse-engineering for interoperability). It is not intended to compete with,
> substitute for, or harm WHOOP's products or services.
>
> See [`DISCLAIMER.md`](DISCLAIMER.md) for the full notice, including a good-faith takedown
> contact.

## What's here

| Path | What it is |
|---|---|
| `protocol/` | The canonical decode schema — single source of truth. |
| `Packages/WhoopProtocol/` | The Swift decoder (ports the Python reference; cross-language parity-tested). |
| `Packages/WhoopStore/` | Local on-device store (GRDB). |
| `ios/` | The SwiftUI + CoreBluetooth app. |
| `server/` | Optional self-hosted datastore + ingest (FastAPI + TimescaleDB) and the `whoop-protocol` Python package. |
| `dashboard/` | A Mac BLE reference/inspection tool used during development. |
| `re/`, `FINDINGS.md` | Reverse-engineering scripts and the protocol reference write-up. |
| `docs/` | Design specs and implementation plans. |

Start with `docs/specs/2026-05-23-openwhoop-ios-app-design.md` and `FINDINGS.md`.

## Supported hardware

WHOOP 4.0 only. Other generations use different BLE protocols and are not supported.

## Building & running

- **iOS app** — open `ios/` (project generated via XcodeGen / SwiftPM). Copy
  `ios/OpenWhoop/Config/Secrets.example.xcconfig` → `Secrets.xcconfig` and fill in your own
  server URL + API key (the real file is gitignored).
- **Server** — see [`server/README.md`](server/README.md): `cp .env.example .env`, set
  `DATA_ROOT`, then `docker compose up -d --build`.
- **RE scripts (`re/`)** — these depend on third-party clones that are intentionally **not**
  bundled (see below and `re/README.md`); copy `re/device_local.example.py` →
  `re/device_local.py` with your own device identifiers. They are not needed to build the app.

No vendor software and no third-party clones are included in this repository (they are
gitignored). The committed code is **entirely original work** plus factual protocol knowledge —
observed from Bluetooth traffic to and from the author's own device — documented in `FINDINGS.md`.
See [`DISCLAIMER.md`](DISCLAIMER.md).

## Credits & provenance

This work builds on prior community reverse-engineering of the WHOOP protocol. The framing,
command, and event identifiers in `protocol/whoop_protocol.json` were derived from independent
reverse-engineering and from these projects — thanks to their authors:

- [`bWanShiTong/openwhoop`](https://github.com/bWanShiTong/openwhoop) — Rust reference whose
  type-47 (V24/V12) biometric decode layout and sleep/wake stillness classifier informed the
  decoding here; the HRV and strain modules under `server/ingest/app/analysis/` were **ported**
  from its `openwhoop-algos` and adapted.
- [`jogolden/whoomp`](https://github.com/jogolden/whoomp) — a community protocol reference
  (CRC, framing, packet types).
- [`bWanShiTong/reverse-engineering-whoop`](https://github.com/bWanShiTong/reverse-engineering-whoop)
  and [`christianmeurer/whoop-reader`](https://github.com/christianmeurer/whoop-reader) —
  earlier BLE exploration.
