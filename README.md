# music-student

Local development environment for the GTFS-RT project. Runs all services with a single command.

## Quickstart

1. Clone all repos as siblings:
   ```bash
   git clone <redis-gtfs-rt-api>
   git clone <schedule-foamer>
   git clone <vehicle-poser>
   git clone <hell-gate-bridge>
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
| 5432 | PostgreSQL |
| 6379 | Redis |
| 5555 | Flower (Celery UI, no auth) |
| 8001 | Admin app (direct, no auth) |
| 8090 | Keycloak OIDC provider |
| 8025 | Mailpit (catches all dev mail) |
| 5556 | Dex OIDC provider (legacy — Traccar only, pending cutover) |
| 8082 | Traccar web UI + REST API (PoC) |
| 5055 | Traccar phone-client protocol (osmand) |

## Dev Credentials

**Admin login** (via http://localhost:4180):
- alice@local / password
- bob@local / password

**Keycloak admin console** (http://keycloak:8090/admin): `admin` / `admin`

## Identity (Keycloak)

Keycloak replaced Dex as the OIDC provider for the admin app, because a person
must be able to sign in with GitHub *or* Google and land on the same account —
Dex cannot link accounts at all.

**Requires `keycloak` to resolve to 127.0.0.1 on the host** (`/etc/hosts`
entry), the same trick the Dex setup needed. The issuer URL is baked into every
token, so the browser and the other containers must reach Keycloak at the
identical `http://keycloak:8090`.

```
127.0.0.1  keycloak
```

### Fake upstream providers

So the linking flows can be exercised offline, the dev stack brokers to two
*fake* providers that are just extra realms in the same Keycloak — no real
GitHub/Google OAuth apps needed. All dev passwords are `password`.

| Realm | Users | Purpose |
|---|---|---|
| `gtfs` | alice@local, bob@local | the real realm; local login + brokering |
| `fake-github` | alice@local, carol@local | stands in for GitHub |
| `fake-google` | alice@local | stands in for Google |

That gives you all three cases to test:

- **New user** — "GitHub" → `carol` — no such account, so one is created silently.
- **Existing email** — "GitHub" → `alice` — Keycloak detects `alice@local`
  already exists and prompts *"an account already exists, link it?"*.
  Confirm, then verify by email (see it in Mailpit at
  <http://localhost:8025>) or by re-entering alice's password.
- **Second provider** — "Google" → `alice` — same prompt, third identity on the
  same account.

Once linked, a logged-in user manages their providers in Keycloak's account
console: <http://keycloak:8090/realms/gtfs/account> → Account security → Linked
accounts.

To point dev at *real* GitHub/Google apps instead, replace the `github`/`google`
entries in `dev/keycloak/gtfs-realm.json` with `"providerId": "github"` /
`"google"` and your client id/secret.

> **Realm import is create-only.** Keycloak skips a realm that already exists,
> so editing `dev/keycloak/*.json` has no effect on a stack that has already
> booted. To pick up changes:
> `docker compose down keycloak && docker compose exec db dropdb -U postgres keycloak && docker compose up -d keycloak`
>
> That re-import mints **new user UUIDs**, and the UUID is the `sub` claim that
> cafe-car stores as `identity.provider_subject`. Every existing person then
> looks like a brand-new account with none of their feeds. Prefer patching the
> live realm with `kcadm.sh` (see below) over re-importing, unless you are also
> wiping the cafe-car database — see "Resetting local state" below.

### Resetting local state

If admin access looks broken (a feed owned by an account you can't log back
in as — e.g. after an OIDC provider change like the Dex→Keycloak cutover, see
above), or Keycloak/cafe-car state has just drifted from `dev/*` config,
don't patch it in place — this stack is local-only, so it's cheaper to start
over:

```bash
./scripts/reset.sh
```

This wipes Postgres (both cafe-car's app DB and the `keycloak` DB living in
the same instance) and Redis, brings the stack back up, re-imports the
Keycloak realm fresh, bootstraps the `alice@local` cafe-car account and
Traccar's first admin account, and reprovisions the three default feeds
(`amtrak`, `columbia-county`, `west` — see `scripts/provision_default_feeds.sh`,
which you can also run on its own to reprovision without a full reset).
Anything created by hand (extra feeds, trackers, Keycloak users) is gone
after this — re-create it, or extend `provision_default_feeds.sh`.

#### Patching a realm that already exists

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8090 --realm master --user admin --password admin
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh update \
  identity-provider/instances/github -r gtfs -s trustEmail=true
```

#### Brokered logins must arrive with a verified email

Both brokers are `"trustEmail": true`. Real GitHub and Google only release
addresses they have themselves verified, so Keycloak may mark the imported user
`emailVerified`. **This is load-bearing, not cosmetic**: cafe-car matches a
person to a pending feed invite — and to a link/merge candidate — only on a
*verified* address. With `trustEmail: false` and the realm's `verifyEmail: false`,
first-broker-login creates the user unverified, and a feed shared with that
address silently never reaches them.

A broker that does *not* verify addresses must stay `trustEmail: false`; turn on
the realm's `verifyEmail` instead so Keycloak does the checking itself.

Users created before this was fixed keep `emailVerified = false`; flip one with
`kcadm.sh update users/<uuid> -r gtfs -s emailVerified=true`.

The `oauth2-proxy` client also carries an `identity_provider` protocol mapper (a
user-session-note mapper) so tokens say which broker a session came through.
cafe-car stores it as `identity.broker_alias` and shows it on `/account`; a
direct realm login has no such note and shows as "Direct".

**PostgreSQL**: `postgres` / `mysecretpassword`

**Realtime ingest**: there is no MQTT broker anymore. Driver positions flow
through **Traccar** → `vehicle-poser` shim → Redis (see below). Amtrak positions
and trip-updates, and the `simulate_trip.py` sim, POST directly to cafe-car's
`/ingest/*` API (shared bearer token `dev-ingest-token`).

**Traccar** (http://localhost:8082): on a fresh database, register the first
account — it becomes admin. "Login with OpenID" goes through Dex (e.g.
alice@local / password) and auto-creates a regular user, but only after
Registration is enabled in Settings → Server → Permissions (it turns off once
the first admin exists). Dex-federated users cannot become admin automatically
(Dex static users carry no groups claim). Requires `dex` to resolve to
127.0.0.1 on the host (`/etc/hosts` entry) so the browser can reach the
issuer URL.

## Vehicle locations (Traccar)

Vehicle positions are ingested through **Traccar** → `vehicle-poser` HTTP shim →
Redis (`vehicle:{username}:{deviceId}`, 60s TTL) → cafe-car. This replaced the
retired OwnTracks → MQTT path. Drivers are provisioned with a QR / config URL
generated per Driver in the cafe-car admin app. See **[docs/traccar.md](docs/traccar.md)**
for the architecture, auth/data model, gotchas, and retention.

Traccar persists every fix to the `traccar` Postgres DB and has no built-in
retention — prune with `scripts/traccar_retention.sql` (see docs).

## Amtrak & simulated trips (cafe-car ingest API)

Producers that already know their own `trip_id` — `hell-gate-bridge` (Amtrak)
and `cafe-car/scripts/simulate_trip.py` — POST straight to cafe-car's
`/ingest/position` and `/ingest/trip-update` (bearer token `INGEST_API_TOKEN`).
The trip-update endpoint carries Amtrak's **own** per-stop predicted arrival/
departure times, which cafe-car serves as multiple `stop_time_update`s. This
replaced the old NanoMQ broker (retired in Phase 7).

`trip-updogger` still runs, but only as the fallback for producers that supply
no predictions of their own — chiefly the Traccar path, whose positions are bare
lat/lon. It sweeps `vehicle:*` in Redis, projects each fix onto the trip's
scheduled stops, and writes a schedule-derived `trip_update:*`. A source stamp
keeps it from ever overwriting a richer producer's record.

### Dual-run tooling (historical)

The migration was de-risked by running both pipelines into Redis under separate
key namespaces and comparing. Retained for reference:
`docker-compose.dualrun.yml` points the shim at `shadow:vehicle:*` (via
`VEHICLE_KEY_PREFIX`), and `scripts/compare_pipelines.py` (read-only) diffs the
live vs shadow feeds per driver.
