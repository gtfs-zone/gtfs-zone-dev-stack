# music-student

Local development environment for the GTFS-RT project. Runs all services with a single command.

## Quickstart

1. Clone all repos as siblings:
   ```bash
   git clone <redis-gtfs-rt-api>
   git clone <schedule-foamer>
   git clone <trip-updogger>
   git clone <vehicle-poser>
   git clone <music-student>
   ```

2. Copy the example env file:
   ```bash
   cd music-student
   cp .env.example .env
   ```

3. Start everything:
   ```bash
   docker compose up --build
   ```

## Port Map

| Port | Service |
|------|---------|
| 4180 | Admin app via oauth2-proxy |
| 8000 | GTFS-RT public API |
| 1883 | MQTT broker (NanoMQ) |
| 5432 | PostgreSQL |
| 6379 | Redis |
| 5555 | Flower (Celery UI, no auth) |
| 8001 | Admin app (direct, no auth) |
| 5556 | Dex OIDC provider |
| 8082 | Traccar web UI + REST API (PoC) |
| 5055 | Traccar phone-client protocol (osmand) |

## Dev Credentials

**Admin login** (via http://localhost:4180):
- alice@local / password
- bob@local / password

**PostgreSQL**: `postgres` / `mysecretpassword`

**MQTT**: any Driver username/password configured in the admin app.

**Traccar** (http://localhost:8082): on a fresh database, register the first
account — it becomes admin. "Login with OpenID" goes through Dex (e.g.
alice@local / password) and auto-creates a regular user, but only after
Registration is enabled in Settings → Server → Permissions (it turns off once
the first admin exists). Dex-federated users cannot become admin automatically
(Dex static users carry no groups claim). Requires `dex` to resolve to
127.0.0.1 on the host (`/etc/hosts` entry) so the browser can reach the
issuer URL.

## Dual-run comparison (OwnTracks → Traccar migration)

De-risk the OwnTracks→Traccar cutover by running both pipelines into the same
Redis DB and comparing before flipping cafe-car onto the Traccar feed. The
Traccar shim writes to a **shadow key namespace** so it never clobbers the live
`vehicle:*` keys cafe-car serves.

```bash
# Start the stack with the shim writing shadow:vehicle:* instead of vehicle:*
docker compose -f docker-compose.yml -f docker-compose.dualrun.yml up --build

# With the live OwnTracks feed also writing vehicle:*, compare the two per driver
python scripts/compare_pipelines.py --redis-url redis://localhost:6379/1
```

`scripts/compare_pipelines.py` is read-only. Per driver it reports position
freshness (`live_age`/`shadow_age`), coordinate delta (`Δcoord_m`), and whether
the resolved `trip_id` agrees. Aim for **both feeds present, small Δcoord, and
matching trip_id** across a real route before cutover. Setup time, iOS
background reliability, and route-switch friction are judged with a real
operator, not this script. The isolation knob is `VEHICLE_KEY_PREFIX` on
`vehicle-poser` (default `vehicle`; `shadow:vehicle` in the override).
