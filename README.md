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
| 4180 | yard-master SPA and the `/api` it calls, via oauth2-proxy. The old SQLAdmin pages live here too |
| 8000 | GTFS-RT public API |
| 5432 | PostgreSQL |
| 6379 | Redis |
| 5555 | Flower (Celery UI, no auth) |
| 8001 | Admin app (direct, no auth) |
| 8090 | Keycloak OIDC provider |
| 8025 | Mailpit (catches all dev mail) |
| 8082 | Traccar web UI + REST API (PoC) |
| 5055 | Traccar phone-client protocol (osmand) |
| - | yard-master (nginx, no host port; reached only through 4180) |
| 8091 | yard-master `pnpm dev` (Vite dev server, HMR, not routed through oauth2-proxy) |

## Dev Credentials

**Admin login** (via http://localhost:4180):
- alice@local / password
- bob@local / password

**Keycloak admin console** (http://keycloak:8090/admin): `admin` / `admin`

## What is behind :4180

One oauth2-proxy fronts two apps, which is how prod is arranged on
`manage.rt.gtfs.zone`: nginx serves the SPA at `/`, and `/api/*` on the same
hostname goes to cafe-car. Same origin on purpose, so there is no CORS, no
preflight on writes, and the `X-Auth-Request-*` headers arrive untouched.
`OAUTH2_PROXY_UPSTREAMS` is the local stand-in for Traefik's path rules:

| Path | Goes to |
|---|---|
| `/` and everything unmatched | `yard-master` (nginx, the SPA) |
| `/api/*` | `admin` (cafe-car's JSON API) |
| `/account`, `/account/*` | `admin` (identity linking, still server-rendered) |
| `/feed/*`, `/tracker/*`, `/tracker-rule/*`, `/service-alert/*`, `/informed-entity/*`, `/statics/*` | `admin` (the old SQLAdmin pages) |

The old admin's index page is the one casualty: `/` now belongs to the SPA. Its
list and detail pages are still there, so `http://localhost:4180/feed/list`
reaches SQLAdmin for a side-by-side comparison.

**Object storage (Garage).** `garage` and `garage-init` stand in for the same
`dxflrs/garage` binary prod runs in k3s: `S3_ENDPOINT=http://garage:3900`
against the `gtfs-feeds` bucket, holding uploaded GTFS zips for `admin` to
write/serve and for `schedule-foamer` to read. `garage-init` applies the
layout and imports the access key once, on first boot; `garage`'s own health
check only means "reachable," not "usable," which is why `garage-init` exists
as a separate step.

**The SPA is not built by this stack.** Its `dist/` is bind-mounted, so build it
in the yard-master checkout at least once before `:4180` will show anything:

```bash
cd ../yard-master
VITE_RT_BASE=http://localhost:8000 pnpm build
```

Without `VITE_RT_BASE` a production build resolves path-only feed URLs against
the deployed feed server rather than this stack's `api` on :8000. Re-run this
after every change you want to see at `:4180`; an empty `dist/` shows up as a
404 at `/`, not as an error.

**For a real edit loop, use `pnpm dev` instead of rebuilding `dist/`.** It is
its own dev server at `http://localhost:8091` (not routed through oauth2-proxy),
with real Vite HMR. It forges the `X-Auth-Request-*` headers oauth2-proxy would
normally set, logging in as alice by default (a real Keycloak-issued UUID looked
up from this stack's `keycloak`, so it's the same account `:4180` gives her; see
`vite.config.ts` for `DEV_SUBJECT`/`DEV_EMAIL`/`DEV_NAME`/`DEV_USERNAME` to log
in as someone else), and proxies `/api` straight to `admin` on :8001. `RT_BASE`
resolves to this stack's `api` on :8000 automatically in dev mode, no env var
needed:

```bash
cd ../yard-master
pnpm dev
```

`:4180` is still the one to use for testing same-origin behavior against the
real nginx artifact and real oauth2-proxy headers.

## Identity (Keycloak)

Keycloak is the OIDC provider for both the admin app (behind oauth2-proxy) and
Traccar (a separate client with its own login). It replaced Dex because a person
must be able to sign in with GitHub *or* Google and land on the same account,
which Dex cannot do at all.

**Requires `keycloak` to resolve to 127.0.0.1 on the host** (`/etc/hosts`
entry). The issuer URL is baked into every token, so the browser and the other containers must reach Keycloak at the
identical `http://keycloak:8090`.

```
127.0.0.1  keycloak
```

### Realm client scopes

`dev/keycloak/gtfs-realm.json` must not carry a top-level `clientScopes` list.
Keycloak creates its built-in scopes (`profile`, `email`, `roles`, `basic`, ...)
only for a realm that does not define its own, so a list here replaces them
rather than adding to it. Every login then dies at the auth endpoint with
`invalid_scope`, and the account console answers "Sorry, an unexpected error has
occurred". Extra claims go on a client's `protocolMappers` instead, which is
where the `groups` claim oauth2-proxy passes to cafe-car comes from.

### Imported users need a default role

A user in a realm import that lists no `realmRoles` gets none, not even
`default-roles-<realm>`, which is where `view-profile` and `manage-account`
come from. Without it the account console loads and then dies with "Something
went wrong", because its REST calls come back 401. Every human user in
`dev/keycloak/*.json` names its realm's default role for that reason.

### Fake upstream providers

So the linking flows can be exercised offline, the dev stack brokers to two
*fake* providers that are just extra realms in the same Keycloak: no real
GitHub/Google OAuth apps needed. All dev passwords are `password`.

| Realm | Users | Purpose |
|---|---|---|
| `gtfs` | alice@local, bob@local | the real realm; local login + brokering |
| `fake-github` | alice@local, carol@local | stands in for GitHub |
| `fake-google` | alice@local | stands in for Google |

That gives you all three cases to test:

- **New user**: "GitHub" → `carol`; no such account, so one is created silently.
- **Existing email**: "GitHub" → `alice`; Keycloak detects `alice@local`
  already exists and prompts *"an account already exists, link it?"*.
  Confirm, then verify by email (see it in Mailpit at
  <http://localhost:8025>) or by re-entering alice's password.
- **Second provider**: "Google" → `alice`; same prompt, third identity on the
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
> `docker compose down keycloak && docker compose exec db dropdb -U postgres keycloak && docker compose exec db createdb -U postgres -O keycloak keycloak && docker compose up -d keycloak`
>
> That re-import mints **new user UUIDs**, and the UUID is the `sub` claim that
> cafe-car stores as `identity.provider_subject`. Every existing person then
> looks like a brand-new account with none of their feeds. Prefer patching the
> live realm with `kcadm.sh` (see below) over re-importing, unless you are also
> wiping the cafe-car database (see "Resetting local state" below).

### Resetting local state

If admin access looks broken (a feed owned by an account you can't log back
in as, e.g. after an OIDC provider change), or Keycloak/cafe-car state has
just drifted from `dev/*` config,
don't patch it in place; this stack is local-only, so it's cheaper to start
over:

```bash
./scripts/reset.sh
```

This wipes Postgres (both cafe-car's app DB and the `keycloak` DB living in
the same instance) and Redis, brings the stack back up, re-imports the
Keycloak realm fresh, bootstraps the `alice@local` cafe-car account and
Traccar's first admin account, and reprovisions the three default feeds
(`amtrak`, `columbia-county`, `west`; see `scripts/provision_default_feeds.sh`,
which you can also run on its own to reprovision without a full reset).
Anything created by hand (extra feeds, trackers, Keycloak users) is gone
after this; re-create it, or extend `provision_default_feeds.sh`.

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
person to a pending feed invite (and to a link/merge candidate) only on a
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

**PostgreSQL**: superuser `postgres` / `mysecretpassword`. Each service has its
own role and database, matching prod's CNPG layout: `rt_api` / `rt_api` (cafe-car
and Celery), `keycloak` / `keycloak`, `traccar` / `traccar`. See
`dev/postgres/init-roles.sql`, which only runs on a fresh `db` volume.

**Realtime ingest**: there is no MQTT broker anymore. Driver positions flow
through **Traccar** → `vehicle-poser` shim → Redis (see below). Amtrak positions
and trip-updates, and the `simulate_trip.py` sim, POST directly to cafe-car's
`/ingest/*` API (shared bearer token `dev-ingest-token`).

**Traccar** (http://localhost:8082) is **admin-only**. "Login with OpenID" goes
to Keycloak, and `openid.allowGroup` refuses anyone outside the `gtfs-admins`
group at the callback: they get no Traccar account at all. Members who pass are
made Traccar administrators by `openid.adminGroup`, so they see every device
without any per-user device sharing.

Locally that means **alice can log in and bob cannot** -- `scripts/reset.sh`
puts alice in the group and deliberately leaves bob out, which is the whole test
matrix for the gate. `admin@local` / `admin` remains as a local password
break-glass account, and is what cafe-car uses for the REST API.

`scripts/reset.sh` turns the self-registration form off, matching prod;
`openid.allowRegistration` is what still lets a group member provision
themselves on first login.

**Admin app** (http://localhost:4180) stays open to every realm account, unlike
Traccar. What changes for a `gtfs-admins` member is scope: they see and edit
every feed, tracker, rule and alert rather than only their own, and they get the
owner-only controls (share, remove, revoke, transfer) on feeds they do not own.
A banner on the sharing panel says when that is why the controls are there.

cafe-car reads the group from the `groups` claim in the access token
oauth2-proxy forwards; the group name is the `ADMIN_GROUP` setting, defaulting
to `gtfs-admins`. `scripts/reset.sh` puts alice in the group, so the bootstrapped
local account is an admin in both apps.

## Vehicle locations (Traccar)

Vehicle positions are ingested through **Traccar** → `vehicle-poser` HTTP shim →
Redis (`vehicle:{username}:{deviceId}`, 60s TTL) → cafe-car. This replaced the
retired OwnTracks → MQTT path. Drivers are provisioned with a QR / config URL
generated per Driver in the cafe-car admin app. See **[docs/traccar.md](docs/traccar.md)**
for the architecture, auth/data model, gotchas, and retention.

Traccar persists every fix to the `traccar` Postgres DB and has no built-in
retention: prune with `scripts/traccar_retention.sql` (see docs).

## Amtrak & simulated trips (cafe-car ingest API)

Producers that already know their own `trip_id`, `hell-gate-bridge` (Amtrak)
and `cafe-car/scripts/simulate_trip.py`, POST straight to cafe-car's
`/ingest/position` and `/ingest/trip-update` (bearer token `INGEST_API_TOKEN`).
The trip-update endpoint carries Amtrak's **own** per-stop predicted arrival/
departure times, which cafe-car serves as multiple `stop_time_update`s. This
replaced the old NanoMQ broker (retired in Phase 7).

`trip-updogger` still runs, but only as the fallback for producers that supply
no predictions of their own, chiefly the Traccar path, whose positions are bare
lat/lon. It sweeps `vehicle:*` in Redis, projects each fix onto the trip's
scheduled stops, and writes a schedule-derived `trip_update:*`. A source stamp
keeps it from ever overwriting a richer producer's record.

### Dual-run tooling (historical)

The migration was de-risked by running both pipelines into Redis under separate
key namespaces and comparing. Retained for reference:
`docker-compose.dualrun.yml` points the shim at `shadow:vehicle:*` (via
`VEHICLE_KEY_PREFIX`), and `scripts/compare_pipelines.py` (read-only) diffs the
live vs shadow feeds per driver.
