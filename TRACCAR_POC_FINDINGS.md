# Traccar PoC — Findings

Lab spike for `../deploy-gtfs-rt/TRACCAR_MIGRATION_FEASIBILITY.md` §9.1. Traccar
is running in the local compose stack: web UI + REST, Postgres storage, Dex SSO,
and phone-client ingestion all verified end-to-end.

## What was added

- **`docker-compose.yml`** — `traccar` service (`traccar/traccar:latest`, ports
  `8082` web/API and `5055` phone-client protocol) + a one-off `traccar-db-init`
  that idempotently creates a `traccar` database in the existing Postgres container.
- **`dev/traccar/traccar.xml`** — points at Postgres and at Dex via OIDC
  auto-discovery (`openid.issuerUrl: http://dex:5556`); commented-out Redis
  forwarding block for the next spike.
- **`dev/dex/config.yaml`** — `traccar` static client, redirect URI
  `http://localhost:8082/api/session/openid/callback`.
- README + CLAUDE.md service-map entries.

## How to look at it

Open **http://localhost:8082**. Log in as `admin@local` / `admin`, or click
"Login with OpenID" → Dex (`alice@local` / `password`).

## Verified

- Liquibase migrations ran cleanly into the new `traccar` Postgres database.
- First internal account registered → automatically became admin.
- OIDC: "Login with OpenID" → Dex → redirected back, auto-created a regular
  (non-admin) Traccar user.
- Ingestion: registered device `test123`, posted a fix to port 5055 (osmand
  protocol) → stored, device shows "online".

## Gotchas (both worked around; relevant for prod)

1. **OIDC auto-provisioning needs Registration enabled.** It's a DB-backed
   server flag (off once the first admin exists), not a config-file setting.
   Enable via Settings → Server → Permissions → Registration, or
   `PUT /api/server {"registration": true}`. Must be redone on a fresh volume.
2. **Dex users can't auto-become admin.** Dex `staticPasswords` emit no `groups`
   claim, so `openid.adminGroup` has nothing to match. Prod would need a Dex
   connector that provides groups, or a manual admin flip. Internal password
   login was kept enabled as the admin path in.

## Auth & data model (Phase 3)

Three roles, deliberately kept simple:

| Role | Who | Auth | Traccar object |
|---|---|---|---|
| **Admin** | us (operators) | internal password (`admin@local`) | administrator user; owns the REST-created fleet devices |
| **Manager** | bus company | Dex OIDC ("Login with OpenID") | regular user, auto-provisioned on first login |
| **Driver** | the vehicle | none — device-only, QR-provisioned | Device (`uniqueId = username`), no user account |

Verified on the live stack: server has `registration:true`, `openIdEnabled:true`,
`openIdForce:false`; a first-time Dex login auto-creates a regular Traccar user.

**Registration flag posture: keep `registration=true`.** It is what lets OIDC
auto-provision manager accounts on first login; disabling it breaks Dex-manager
onboarding. Tradeoff — it also exposes self-service account registration in the web
UI. Acceptable in dev; prod hardening (deferred) is `openid.force=true` to force SSO
and hide the internal register/login form, gating account creation at Dex.

**Known gaps (deferred, not blockers):**

1. **Managers see no devices by default.** Traccar scopes device visibility
   per-user, and fleet devices are owned by `admin@local` (cafe-car creates them via
   REST as that account). A freshly provisioned manager sees an empty device list
   until devices are explicitly shared — `POST /api/permissions {userId, deviceId}`,
   assigning devices to the manager, or promoting them to a Traccar admin. The real
   fleet layer will need one of these; not built yet.
2. **Dex users can't auto-become admin.** `staticPasswords` emit no `groups` claim,
   so `openid.adminGroup` has nothing to match. Internal `admin@local` stays the
   admin path in; prod would need a Dex connector that emits groups.

## Out of scope (not done)

Redis forwarding, replacing `vehicle-poser`, QR provisioning. Traccar
`:latest` is unpinned — pin before anything real. Traccar's data lives in the
shared `db_data` volume, so `docker compose down -v` wipes it.
