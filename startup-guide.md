# Startup Guide — full reset to three live feeds

Brings the stack up from a clean slate and provisions three feeds:

| Feed | `feed_name` | Position source | Trip resolution | Human step |
|---|---|---|---|---|
| Amtrak | `amtrak` | `hell-gate-bridge` (`SOURCE=amtrak`) polls Amtrak | upstream (explicit `trip_id`) | none |
| Columbia County | `columbia-county` | `hell-gate-bridge-buswhere` (`SOURCE=buswhere`) polls buswhere.com | upstream (explicit `trip_id`) | none |
| West bus | `west` | a real Traccar phone device | server-side, from `TrackerRule`s | **driver scans a QR** |

The two pollers authenticate to cafe-car's `/ingest/*` with the shared
`INGEST_API_TOKEN` and publish under a **fixed** `INGEST_VEHICLE_ID` that must
equal a `Tracker.id` — these are wired in `docker-compose.yml`
(`amtrak-live`, `columbia-county`). West's tracker id is a secret pet-name that
the driver's QR encodes; nothing else needs to know it.

Trip resolution keys:
- Pollers POST an explicit `trip_id`, so they need **no** `TrackerRule`s.
- West goes Traccar → `vehicle-poser` → `resolve_tracker_trip(tracker_id)`, which
  needs (a) `TrackerRule`s mapping a schedule window → `trip_id`, and (b) the
  `west` GTFS static loaded so the feed timezone is known. Static loading is
  automatic (schedule-foamer's beat enqueues any feed lacking a load within ~1 min).

---

## 0. Prerequisites

```bash
cd ~/Documents/music-student
[ -f .env ] || cp .env.example .env          # build-context dirs + DB/Redis URLs
```

The provisioning script runs from the **host** against published ports, using the
cafe-car project venv (it already has `railroad_club` on the tracker branch):

```bash
cd ~/Documents/cafe-car && uv sync            # once, if the venv is stale
```

## 1. Full reset + start

```bash
cd ~/Documents/music-student
docker compose down -v          # stop everything and DELETE all volumes
docker compose up --build -d    # rebuild images and start detached
```

Wait until `migrate` has exited 0 and the core services are healthy:

```bash
docker compose ps
docker compose logs -f migrate  # Ctrl-C once you see "alembic upgrade head" complete
```

## 2. Create the owner user (manual, one-time)

`Feed.owner_id` is required, and users are created lazily on first admin login.
Open the admin behind oauth2-proxy and sign in as the fixtured Keycloak user:

- URL: <http://localhost:4180>
- Login: **`alice@local` / `password`**

This needs a `127.0.0.1  keycloak` line in your `/etc/hosts` — the OIDC issuer
URL has to be identical for the browser and for the containers. See the
Identity section of the README.

Loading the admin dashboard creates the `alice@local` `User` row. The
provisioning script matches the owner by email (`--owner-email`, default
`alice@local`), so this is all that's needed.

## 3. Bootstrap the Traccar admin account

West's device creation and QR provisioning use Traccar's REST API with Basic auth
`admin@local / admin`. A **fresh Traccar DB has no users** — Traccar does not
auto-create one here. The first `POST /api/users` (allowed unauthenticated while
`tc_users` is empty) registers that user as administrator:

```bash
curl -s -X POST http://localhost:8082/api/users \
  -H 'Content-Type: application/json' \
  -d '{"name":"Admin","email":"admin@local","password":"admin"}'

# verify: expect one row, administrator = t
docker compose exec -T db psql -U postgres -d traccar \
  -tAc "select email, administrator from tc_users;"
```

This only works on a truly empty user table; if it fails, see **Troubleshooting →
Traccar admin**.

## 4. Provision the three feeds

Run from the cafe-car repo. The `TRACCAR_*` overrides point the script at the
host-published Traccar (the in-container default `http://traccar:8082` won't
resolve from the host):

```bash
cd ~/Documents/cafe-car
export TRACCAR_URL=http://localhost:8082 TRACCAR_EMAIL=admin@local TRACCAR_PASSWORD=admin
```

**Amtrak** (poller; fixed id must match compose `INGEST_VEHICLE_ID=amtrak-live`;
no Traccar device needed — it isn't a phone):

```bash
uv run python scripts/provision_source.py \
  --feed-name amtrak \
  --static-feed-url https://content.amtrak.com/content/gtfs/GTFS.zip \
  --nickname "Amtrak" \
  --tracker-id amtrak-live \
  --skip-traccar
```

**Columbia County** (poller; fixed id must match `INGEST_VEHICLE_ID=columbia-county`):

```bash
uv run python scripts/provision_source.py \
  --feed-name columbia-county \
  --static-feed-url https://raw.githubusercontent.com/columbia-county-ny-transit/gtfs-generator/refs/heads/main/columbia_county_gtfs.zip \
  --nickname "Columbia County" \
  --tracker-id columbia-county \
  --skip-traccar
```

**West bus** (real device: auto-generated secret id + a schedule rule; DO create
the Traccar device so the QR works):

```bash
uv run python scripts/provision_source.py \
  --feed-name west \
  --static-feed-url http://westbusservice.com/west_gtfs.zip \
  --nickname "West Coastal Connection" \
  --rule daily=00:00-23:59=WCCWB
```

### Choosing the West rule (manual)

`--rule DAYS=HH:MM-HH:MM=TRIP_ID`. The example above maps **any** time, any day, to
trip `WCCWB` (route `WCC`, "West's Coastal Connection", the only `DAILY`-service
trip) — convenient so a scan resolves whenever you test. West's timezone is
`America/New_York`, and rule windows are evaluated in that zone.

To use a realistic window instead, inspect the feed and pick a trip + its running
window:

```bash
# routes and their trips
unzip -p example_data/west_gtfs.zip trips.txt | column -s, -t | head
# a trip's actual start/end times
unzip -p example_data/west_gtfs.zip stop_times.txt | awk -F, '$1=="WCCWB"' | head
```

Examples:
- `--rule daily=00:00-23:59=WCCWB` — demo: always resolves to WCCWB.
- `--rule mon-fri=07:00-19:00=WCCWB` — weekday daytime westbound.
- `--rule mon=09:00-13:00=ELLSWB` — Monday-only Ellsworth run (service `MONDAY`).

Pass `--rule` more than once for multiple windows; re-running the command
**replaces** all of that tracker's rules.

## 5. Hand West to a driver (the QR scan)

1. In the admin (<http://localhost:4180>), open **Trackers → West Coastal Connection**.
2. Its detail page renders the provisioning QR / config URL (Traccar Client deep
   link encoding the secret `uniqueId` + server).
3. The driver installs **Traccar Client** and scans the QR. Positions flow:
   phone → Traccar `:5055` → `forward.url` → `vehicle-poser:8080/forward` →
   `resolve_tracker_trip` → Redis `vehicle:<id>:*` → the `west` feed.

> The QR base must be an address the **phone** can reach. The dev default
> `TRACCAR_CLIENT_BASE=http://localhost:5055` only works for a client on this host
> (e.g. an emulator). For a real phone on the LAN, set `TRACCAR_CLIENT_BASE` to the
> host's LAN IP (`http://<LAN-IP>:5055`) on the `api`/`admin` services and re-open
> the QR.

## 6. Verify

```bash
# Feeds exist and GTFS static finished loading (status should become "success")
docker compose exec -T db psql -U postgres -tAc \
  "select f.feed_name, s.status, s.timezone from feed f
   left join gtfs_static_feed s on s.id = f.gtfs_static_feed_id order by f.feed_name;"

# Trackers wired to feeds
docker compose exec -T db psql -U postgres -tAc \
  "select id, nickname, feed_id from tracker order by nickname;"

# Pollers are running clean (look for POSTs / resolved trips, no auth errors)
docker compose logs --tail=30 hell-gate-bridge
docker compose logs --tail=30 hell-gate-bridge-buswhere

# Served GTFS-RT — HTTP status (expect 200)
curl -s -o /dev/null -w "amtrak vp: %{http_code}\n"          http://localhost:8000/amtrak/vehicle_positions.pb
curl -s -o /dev/null -w "columbia vp: %{http_code}\n"        http://localhost:8000/columbia-county/vehicle_positions.pb
curl -s -o /dev/null -w "west vp: %{http_code}\n"            http://localhost:8000/west/vehicle_positions.pb

# Decode a feed's live entity count (uses the api container's protobuf bindings)
docker compose exec -T api python -c "
import urllib.request
from google.transit import gtfs_realtime_pb2 as pb
d=urllib.request.urlopen('http://localhost:8000/amtrak/vehicle_positions.pb').read()
m=pb.FeedMessage(); m.ParseFromString(d); print('amtrak entities:', len(m.entity))"
```

Live vehicles only appear when the upstream actually has moving vehicles:
- **Amtrak**: trains run ~all day, so the `amtrak` feed should show entities within a
  poll cycle (~15 s) of startup — a good end-to-end smoke signal.
- **Columbia County**: only during that system's service hours (0 vehicles otherwise
  is normal — the poller still logs `0 vehicles` each cycle).
- **West**: only after a driver scans the QR *and* a `TrackerRule` window is active.
  To test without a phone, run the simulator in **device mode** — it emulates the
  Traccar Client app (posts fixes to `:5055`), so the whole real path runs and the
  trip is resolved server-side from the rules (replace `<west-id>` with the west
  `Tracker.id` from the query above):
  ```bash
  cd ~/Documents/cafe-car
  uv run scripts/simulate_trip.py --mode device --tracker <west-id> \
    --trip WCCWB --speed 30 --real-time
  ```
  `docker compose logs -f vehicle-poser` should show
  `Stored vehicle:<west-id>:... trip_id=WCCWB` (proving rule resolution), and
  re-decoding `west/vehicle_positions.pb` shows one entity (`trip WCCWB`) for ~60 s
  (the position TTL). The west Traccar device must be provisioned (step 4) or
  `:5055` rejects the fix with HTTP 400.

## Troubleshooting

- **`No 'dex' User with email='alice@local'`** — you skipped step 2. Log into the
  admin once, then re-run.
- **Poller logs show `No active rule` / positions don't appear** — for the pollers
  this is fine (they post explicit `trip_id`). For **west**, it means no
  `TrackerRule` window is currently active, or the `west` GTFS static hasn't loaded
  yet (timezone unknown → resolution returns `None`). Check step 6's status query.
- **Traccar admin** — if step 3 shows no `admin@local` admin (fresh Traccar may
  create a different default), create it in the web UI at <http://localhost:8082>
  with the default account, or via REST, so email is `admin@local` / password
  `admin` (matching the `TRACCAR_EMAIL`/`TRACCAR_PASSWORD` the `api`/`admin`
  services use). Then re-run the `west` provisioning command.
- **`vehicle_positions.pb` 404** — the feed row doesn't exist; re-run its
  provisioning command (check the `feed_name` matches the URL path).
- **Re-provisioning is safe** — the script is idempotent: same `--feed-name` /
  `--nickname` reuse existing rows and the Traccar device; `--rule`s are replaced.
