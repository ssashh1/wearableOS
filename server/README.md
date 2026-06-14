# whoop — datastore + ingest

Backup datastore for the open-source WHOOP project. Receives raw BLE frames
(from the Mac uploader now, the phone later), archives them forever, and stores
decoded HR/RR/event/battery streams in TimescaleDB. Decoding uses the
`whoop-protocol` package (repo `packages/whoop-protocol`).

- `whoop-db` — TimescaleDB. Data at `${DATA_ROOT}/whoop/db`. Not published; only
  `whoop-ingest` reaches it.
- `whoop-ingest` — FastAPI. `POST /v1/ingest` (Bearer `WHOOP_API_KEY`). Raw archived
  to `${DATA_ROOT}/whoop/raw/<device>/<date>/<batch>.zst`; decoded rows in hypertables.

## Deploy
1. `cp .env.example .env` and fill in `WHOOP_API_KEY` + `WHOOP_DB_PASSWORD`.
2. Set `DATA_ROOT` to a host dir for persistent data (db + raw archive), e.g.
   `export DATA_ROOT=/srv/whoop-data`.
3. `docker compose up -d --build` (creates `${DATA_ROOT}/whoop/{db,raw}`).

## Uploader (Mac replay)
    python client/uploader.py path/to/capture.jsonl \
      --url http://localhost:8770 --token "$WHOOP_API_KEY" --device whoop4-dev
Supports both capture formats (full_hex and datalen+data_hex). Clock correlation is
best-effort for replay; the live phone/Mac client supplies a real correlation.

## Tests
    # runtime image deps are requirements.txt; tests also need pytest + httpx:
    pip install -r ingest/requirements-dev.txt
    cd ingest && pytest          # archive (unit) + store/pipeline/api (docker Timescale)
Integration tests spin a throwaway TimescaleDB container; they skip if Docker is absent.

## Dashboard
`whoop-ingest` serves a static datastore dashboard at `/` (e.g. http://<host>:8770).
It reads the API below:
device + time-range picker, HR/battery charts, an events list, a batch browser, and a
hex inspector that re-parses any archived frame (category-colored byte grid + field
readout). Same telemetry-console look as the original live RE dashboard, but reading
stored history instead of a live BLE link.

## Read API (unauthenticated; behind the LAN/tunnel)
    GET /v1/devices
    GET /v1/batches?device=<id>&limit=100
    GET /v1/streams/{hr|rr|events|battery}?device=<id>&from=<unix>&to=<unix>&limit=5000
    GET /v1/batches/{batch_id}/frames     # re-parses the raw .zst archive via whoop-protocol
The dashboard (sub-project A4) consumes these. Writes (`POST /v1/ingest`) stay Bearer-authed.

## Verify
See `VERIFY.md` for the full end-to-end (replay a capture, confirm rows in TimescaleDB).
    curl -s localhost:8770/healthz
