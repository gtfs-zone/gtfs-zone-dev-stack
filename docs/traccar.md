# Traccar vehicle-location pipeline

Driver vehicle positions are ingested through **Traccar**, replacing the retired
OwnTracks → MQTT path. Redis is the stable seam, so `cafe-car` and
`schedule-foamer` are unchanged.

> Amtrak positions/trip-updates and the `simulate_trip.py` sim do **not** go
> through Traccar — they POST directly to cafe-car's `/ingest/*` API. NanoMQ was
> retired in Phase 7.

```
Traccar Client app (phone)
    └─> Traccar server        (:5055 osmand ingest, :8082 web/REST)
            └─> forward.type=json  POST http://vehicle-poser:8080/forward
                    └─> vehicle-poser  (resolves trip_id via TrackerRules)
                            └─> Redis  vehicle:{tracker_id}:{deviceId}  (60s TTL)
                                    ├─> cafe-car      (serves GTFS-RT feeds)
                                    └─> trip-updogger (schedule-derived
                                            trip_update:{trip_id}, 300s TTL)
```

A Traccar fix is bare lat/lon — vehicle-poser sets no `current_stop_sequence`,
`stop_id` or `current_status`, so the vehicle positions feed omits them (GTFS-RT
makes all three optional). `trip-updogger` is what makes such a vehicle locatable
anyway: it projects each fix onto the trip's scheduled stops and publishes a
timed prediction for every stop ahead, from which a consumer can infer the
current stop. Predictions carrying only a delay are not enough for that.

- A driver is provisioned by scanning a QR / config URL generated per Driver in
  the cafe-car admin app. cafe-car auto-creates the matching Traccar device
  (`uniqueId = username`) via REST when the Driver is created.
- The shim writes the **exact** record shape the OwnTracks bridge used, keyed
  `vehicle:{username}:{deviceId}` — see `vehicle-poser`'s README for the field
  mapping (knots→m/s, ISO-8601→epoch, etc.).
- Config lives in `dev/traccar/traccar.xml` (Postgres storage, Dex OIDC,
  `forward.*` to the shim). The `traccar` DB is created by the one-off
  `traccar-db-init` service inside the shared Postgres container.

## Auth & data model

Three roles, deliberately kept simple:

| Role | Who | Auth | Traccar object |
|---|---|---|---|
| **Admin** | us (operators) | internal password (`admin@local` / `admin`) | administrator user; owns the REST-created fleet devices |
| **Manager** | bus company | Dex OIDC ("Login with OpenID") | regular user, auto-provisioned on first login |
| **Driver** | the vehicle | none — device-only, QR-provisioned | Device (`uniqueId = username`), no user account |

Verified on the live stack: `registration:true`, `openIdEnabled:true`,
`openIdForce:false`; a first-time Dex login auto-creates a regular Traccar user.

**Registration flag posture: keep `registration=true`.** It is what lets OIDC
auto-provision manager accounts on first login; disabling it breaks Dex-manager
onboarding. Tradeoff — it also exposes self-service account registration in the
web UI. Acceptable in dev; prod hardening (deferred) is `openid.force=true` to
force SSO and hide the internal register/login form, gating account creation at
Dex.

## Known gaps (deferred, not blockers)

1. **Managers see no devices by default.** Traccar scopes device visibility
   per-user, and fleet devices are owned by `admin@local` (cafe-car creates them
   via REST as that account). A freshly provisioned manager sees an empty device
   list until devices are explicitly shared — `POST /api/permissions {userId,
   deviceId}`, assigning devices to the manager, or promoting them to a Traccar
   admin. The real fleet layer will need one of these.
2. **Dex users can't auto-become admin.** Dex `staticPasswords` emit no `groups`
   claim, so `openid.adminGroup` has nothing to match. Internal `admin@local`
   stays the admin path in; prod would need a Dex connector that emits groups.
3. **The QR / `uniqueId` is a bearer credential** — anyone who photographs it can
   impersonate that driver. Acceptable for public transit data now; per-device
   tokens / plausibility filtering are deferred.

## Retention

Traccar has **no config-file retention key** (confirmed on 6.14.5) — it persists
every fix to `tc_positions` indefinitely. This is new durable data the OwnTracks
path never kept, and it lives in the shared `db_data` volume.

- **Dev:** no automatic purge. `docker compose down -v` wipes the `traccar` DB
  (along with the `registration`/admin state) anyway. Prune manually when needed
  with `scripts/traccar_retention.sql` (default 30 days; `-v days=<n>` to
  override).
- **Prod:** schedule `scripts/traccar_retention.sql` (cron / pg_cron / k8s
  CronJob) and size Postgres storage accordingly. Wiring an always-on cron
  service into the dev compose stack was intentionally skipped as noise; prod
  provisioning is Terraform scope (out of scope here).

## Gotchas

- The `:5055` osmand endpoint / QR base must be an address the **phone** can
  reach — `localhost` only works from the host. Parameterized via
  `TRACCAR_CLIENT_BASE`; set it to the public Traccar hostname in prod.
- `docker compose down -v` wipes the shared `db_data` volume → Traccar data +
  the `registration`/admin flags reset. Re-enable Registration (Settings →
  Server → Permissions, or `PUT /api/server {"registration": true}`) on a fresh
  volume for OIDC auto-provisioning to work again.
- Browser OIDC login needs `dex` to resolve to `127.0.0.1` on the host
  (`/etc/hosts` entry) so the redirect to the issuer URL works.
