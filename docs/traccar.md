# Traccar vehicle-location pipeline

Driver vehicle positions are ingested through **Traccar**, replacing the retired
OwnTracks → MQTT path. Redis is the stable seam, so `cafe-car` and
`schedule-foamer` are unchanged.

> Amtrak positions/trip-updates and the `simulate_trip.py` sim do **not** go
> through Traccar; they POST directly to cafe-car's `/ingest/*` API. NanoMQ was
> retired in Phase 7.

```
Traccar Client app (phone)
    └─> Traccar server        (:5055 osmand ingest, :8082 web/REST)
            └─> forward.type=json  POST http://vehicle-poser:8080/forward
                    └─> vehicle-poser  (resolves trip_id via TrackerRules)
                            └─> Redis  vehicle:{tracker_id}:{deviceId}  (60s TTL)
                                    ├─> cafe-car      (serves GTFS-RT feeds)
                                    └─> trip-updogger (schedule-derived
                                            trip_update:{tracker_id}:{trip_id}, 300s TTL)
```

A Traccar fix is bare lat/lon: vehicle-poser sets no `current_stop_sequence`,
`stop_id` or `current_status`, so the vehicle positions feed omits them (GTFS-RT
makes all three optional). `trip-updogger` is what makes such a vehicle locatable
anyway: it projects each fix onto the trip's scheduled stops and publishes a
timed prediction for every stop ahead, from which a consumer can infer the
current stop. Predictions carrying only a delay are not enough for that.

- A driver is provisioned by scanning a QR / config URL generated per Driver in
  the cafe-car admin app. cafe-car auto-creates the matching Traccar device
  (`uniqueId = username`) via REST when the Driver is created.
- The shim writes the **exact** record shape the OwnTracks bridge used, keyed
  `vehicle:{tracker_id}:{deviceId}`; see `vehicle-poser`'s README for the field
  mapping (knots→m/s, ISO-8601→epoch, etc.).
- Config lives in `dev/traccar/traccar.xml` (Postgres storage, Keycloak OIDC,
  `forward.*` to the shim). The `traccar` role and database are created by
  `dev/postgres/init-roles.sql` inside the shared Postgres container. Secrets
  arrive as env vars from the compose service, as in prod.

## Auth & data model

**Traccar is admin-only.** The Manager role is gone: there is no longer any way
for a non-admin to hold a Traccar account.

| Role | Who | Auth | Traccar object |
|---|---|---|---|
| **Admin** | us (operators) | Keycloak OIDC, must be in `gtfs-admins` | administrator user, auto-provisioned on first login; sees every device |
| **Break-glass** | us, when SSO is down | internal password (`admin@local` / `admin`) | administrator user; owns the REST-created fleet devices, and is what cafe-car authenticates as |
| **Driver** | the vehicle | none: device-only, QR-provisioned | Device (`uniqueId = tracker id`), no user account |

The gate is two config keys, both reading the `groups` claim that Keycloak's
`groups` client scope puts in the token (mapped `full.path=false`, so the value
is the bare name and a leading slash would match nothing):

- `openid.allowGroup=gtfs-admins` refuses anyone outside the group at the
  callback. They never get a Traccar user at all.
- `openid.adminGroup=gtfs-admins` makes the ones who pass administrators, which
  is what lets them see every device.

**Registration posture: `registration=false`, `openid.allowRegistration=true`.**
That pairing is the point. The server flag being off closes the self-service
sign-up form in the web UI, which would otherwise be a way straight past the
group gate; `openid.allowRegistration` is what still lets a group member
provision themselves on first OIDC login. `scripts/reset.sh` turns the server
flag off after bootstrapping the break-glass admin.

`openid.force` is deliberately **not** set: it would hide the internal login
form, and that form is the break-glass path when Keycloak is down, as well as
how cafe-car authenticates to the REST API.

## Known gaps (deferred, not blockers)

1. **The QR / `uniqueId` is a bearer credential**: anyone who photographs it can
   impersonate that driver. Acceptable for public transit data now; per-device
   tokens / plausibility filtering are deferred.

## Retention

Traccar has **no config-file retention key** (confirmed on 6.14.5); it persists
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
  reach; `localhost` only works from the host. Parameterized via
  `TRACCAR_CLIENT_BASE`; set it to the public Traccar hostname in prod.
- `docker compose down -v` wipes the shared `db_data` volume → Traccar data and
  the `registration`/admin flags reset. `scripts/reset.sh` re-bootstraps the
  break-glass admin and turns registration back off; OIDC auto-provisioning for
  group members does not depend on that flag (`openid.allowRegistration` covers
  it).
- Browser OIDC login needs `keycloak` to resolve to `127.0.0.1` on the host
  (`/etc/hosts` entry) so the redirect to the issuer URL works.
- A login that bounces back to the Traccar login page with no account created is
  the group gate doing its job: the account is not in `gtfs-admins`. Locally,
  alice is and bob is not.
