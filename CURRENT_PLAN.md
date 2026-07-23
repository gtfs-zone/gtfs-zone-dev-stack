# Plan: Replace OwnTracks with Traccar

## Summary

Migrate vehicle-location ingestion from **OwnTracks → MQTT → vehicle-poser → Redis**
to **Traccar → HTTP forward → (repurposed) vehicle-poser → Redis**, keeping Redis
as the stable seam so `cafe-car`, `trip-updogger`, and `schedule-foamer` stay
untouched. The Traccar PoC (compose service, Postgres `traccar` DB, Dex OIDC,
phone-client ingestion on `:5055`) is already up and verified — see
`TRACCAR_POC_FINDINGS.md`.

The near-term focus is the **driver provisioning experience**: a QR code / config
URL generated per driver in the cafe-car admin app, that configures the Traccar
Client phone app in one scan (server URL + device id + tracking profile). The
end-state functionality is approximately the same as today, with a much better
provisioning UX and a real device/fleet layer underneath.

### Decisions made (locked)

| Decision | Choice |
|---|---|
| Traccar → Redis integration | **Variant B** — thin HTTP shim (repurpose `vehicle-poser`), *not* native `forward.type=redis` (see Gotcha in Phase 2) |
| Device `uniqueId` meaning | **= driver username**; `trip_id` resolved server-side by existing driver-rules (`resolve_driver_trip`) |
| Trip resolution | Always schedule-based (the old "auto" path); the explicit-`trip_id`-in-topic override is dropped |
| QR/URL generation | **cafe-car admin, per Driver** |
| Traccar device creation | **Auto-create via Traccar REST** when a Driver is created (`uniqueId = username`) |
| Tracking profile | **Single global default** baked into every QR |
| Manager/human auth | **Federate to Dex (OIDC)** — already wired in PoC; drivers get **no accounts** (device-only) |
| Migration scope | **Full** — includes dual-run and decommission of OwnTracks + old MQTT path |
| Auth hardening (Dex groups → Traccar admin) | **Deferred** — keep PoC state (internal admin + OIDC auto-provision of regular users), note the gap |

## Relevant Context

**Current data path & contracts**

- `vehicle-poser/src/vehicle_poser/main.py` — subscribes `owntracks/+/+`, treats
  MQTT username as `driver`, device slug as `trip_id` (or `"auto"` → driver-rules),
  writes Redis key `vehicle:{user}:{device}` with **60s TTL**, value:
  `{driver, trip_id, lat, lon, bearing, speed(m/s), timestamp}`.
- `railroad_club/trip_resolver.py::resolve_driver_trip(username, session)` —
  schedule/weekday/time-window lookup against `DriverRule`, last rule wins.
- `cafe-car/src/cafe_car/routers/gtfs_rt.py:59,114` — reads
  `vehicle:{driver.username}:*`, expects fields `driver, trip_id, lat, lon,
  bearing, speed, route_id?`. **This is the contract the shim must reproduce
  byte-for-byte.**
- `Driver` model has `username` + `feed_id`; drivers are already the unit of
  identity, which is why `uniqueId = username` is the natural mapping.

**Traccar facts confirmed from source/docs**

- `forward.type=json` POSTs `{"position": Position, "device": Device}` to
  `forward.url`. `device.uniqueId` is our key; `position` has
  `latitude, longitude, speed (KNOTS), course, fixTime, attributes{}`.
- `forward.type=redis` (rejected) does `LPUSH positions.<uniqueId>` of the raw
  Position JSON — an **unbounded list, no TTL, no trip_id, wrong key/shape**.
- QR config (Traccar Client 6.8+/9.5.0) encodes a URL:
  `<serverBase>?id=<uniqueId>&accuracy=highest&distance=1&interval=30&heartbeat=3000&wakelock=true&stop_detection=true`.
  Params `&`-concatenated. The confirmed-working URL is the provisioning primitive.
- Traccar REST: `POST /api/devices {name, uniqueId}` creates a device; auth via a
  per-user API token or Basic auth.

**Infra already in place** (`docker-compose.yml`, `dev/traccar/traccar.xml`,
`dev/dex/config.yaml`): `traccar` service (`:8082` web/REST, `:5055` osmand),
`traccar-db-init` (creates `traccar` DB in shared Postgres), Dex `traccar` static
client. `traccar/traccar:latest` is **unpinned** — pin early.

**NanoMQ stays** — still used by `trip-updogger` and `hell-gate-bridge` (Amtrak).
Only the OwnTracks/vehicle-poser MQTT path is being removed.

---

## Phase 1 — Driver provisioning: device auto-creation + QR/URL in admin

The headline UX. When a manager creates a Driver, cafe-car creates the matching
Traccar device (`uniqueId = username`) via REST, and the admin surfaces a QR code
+ copyable config URL that configures the Traccar Client in one scan. No data-path
changes yet — success is verified in the Traccar console (device shows "online").

- [x] Pin the Traccar image (replace `:latest` with a specific tag) in
      `docker-compose.yml`. → pinned to `traccar/traccar:6.14.5` (what `:latest`
      resolved to locally).
- [x] Provision a Traccar REST credential for cafe-car (API token for an admin/
      service user); add `TRACCAR_URL` + `TRACCAR_API_TOKEN` env to the `api`/
      `admin` services in `docker-compose.yml` and cafe-car settings.
      → **Auth is token-OR-basic**: generating a Traccar API token is a manual
      chicken-and-egg step in dev, so the client also accepts Basic auth. Compose
      wires `TRACCAR_URL`/`TRACCAR_EMAIL`/`TRACCAR_PASSWORD` (`admin@local`/`admin`,
      the PoC admin) + `TRACCAR_CLIENT_BASE`; `traccar_api_token` stays optional in
      settings and takes precedence when set. Verified `admin@local:admin` Basic
      auth works against the live `/api/devices`.
- [x] Add a small Traccar REST client in cafe-car (`create_device`, `get_device`,
      idempotent on `uniqueId`). → `cafe_car/traccar.py::TraccarClient`
      (+ `ensure_device`, cached `get_traccar_client()`). Added deps `httpx`,
      `segno`.
- [x] Hook Driver creation → `POST /api/devices {name: username, uniqueId: username}`;
      handle already-exists gracefully. → in `DriverAdmin.after_model_change`
      (only on `is_created`), best-effort: logs a warning but never blocks driver
      creation if Traccar is down. **Rename/delete sync is a deliberate follow-up**
      — create-only for now (usernames are immutable-ish; stale Traccar devices are
      harmless). Verified `ensure_device` is idempotent against live Traccar.
- [x] Add a config-URL builder: `{TRACCAR_CLIENT_BASE}?id={username}&{DEFAULT_PROFILE}`
      → `build_config_url()`; profile is `settings.traccar_default_profile` (single
      global default). `id` is URL-quoted.
- [x] Render a QR + the raw URL per driver in the admin UI. → **server-side** via
      `segno` (inline SVG, no CDN/offline dependency). `DriverAdmin.details_template
      = driver_detail.html` htmx-loads `/driver/{id}/provisioning-partial`
      (ownership-checked) → `_driver_provisioning.html` (QR + copyable URL). Added a
      "Provisioning" list column linking to the details page.
- [~] Verify end-to-end: create a Driver → device appears in Traccar → scan QR
      with Traccar Client on a real phone → device goes "online", fixes land on
      `:5055`. → **Automated portion done**: REST device create/idempotency/lookup
      verified against live Traccar; admin rebuilt with new deps and serving;
      URL+QR render path verified. **Remaining manual step**: real-phone QR scan +
      OIDC-authed driver-create-through-the-UI (needs a human).

**Gotchas**

- The `:5055` osmand endpoint / QR base must be an address the **phone** can
  reach — `localhost:8082` only works from the host. For real drivers this is the
  public Traccar hostname; parameterize the base URL, don't hardcode.
- The `uniqueId`/QR is a **bearer credential** — anyone who photographs it can
  impersonate that driver. Acceptable for public transit data now; hardening
  (per-device tokens, plausibility filtering) is deferred.
- OIDC user auto-provisioning needs Traccar's `registration` server flag ON
  (PoC gotcha #1), but that *also* allows unknown devices to self-register. Since
  we auto-create devices via REST, decide deliberately whether to keep
  registration on (needed for Dex user auto-provision) — for now, keep the PoC
  behavior and note it.
- Traccar's speed on the wire is **knots**; irrelevant here (Phase 2) but don't
  confuse it with the QR's `interval` (seconds).

## Phase 2 — Traccar → Redis shim (repurpose vehicle-poser)

Replace vehicle-poser's MQTT subscriber with an HTTP endpoint that receives
Traccar's `json` position forward, resolves `trip_id` via driver-rules, and writes
the **exact existing** `vehicle:{username}:{deviceId}` record with a 60s TTL —
so cafe-car/trip-updogger/schedule-foamer need zero changes.

- [x] Rewrite `vehicle-poser` as a tiny HTTP server (FastAPI/aiohttp) exposing
      e.g. `POST /forward`. Keep its Redis + `create_engine` + `resolve_driver_trip`
      wiring; drop `aiomqtt` and the `owntracks/+/+` loop. → FastAPI + uvicorn,
      `POST /forward` + `GET /health`; Redis via a `lifespan` handler. `aiomqtt`
      dropped from deps (added `fastapi`/`uvicorn`), `uv lock` updated, Dockerfile
      CMD `python -m vehicle_poser.main` still runs `main()` → `uvicorn.run`.
- [x] On each POST: read `device.uniqueId` (= username) and `position`. Resolve
      `trip_id = resolve_driver_trip(username)` (always — the schedule path). →
      `resolve_driver_trip` runs in a thread (sync SQLModel session); missing
      `uniqueId` → `{"status":"ignored"}`, never 500.
- [x] Map fields to the current record shape:
      `driver=uniqueId`, `trip_id`, `lat=position.latitude`,
      `lon=position.longitude`, `bearing=position.course`,
      `speed = position.speed * 0.514444` (knots → m/s, 4dp),
      `timestamp = position.fixTime` (epoch). Write
      `SETEX vehicle:{uniqueId}:{position.deviceId or "traccar"} 60 <json>`. →
      done. **Note**: Traccar's `position.deviceId` is the internal numeric device
      id (e.g. `4`), not the username — key becomes `vehicle:{username}:{n}`, still
      matched by cafe-car's `vehicle:{username}:*` scan. `fixTime` arrives ISO-8601,
      parsed to epoch seconds via `_to_epoch`.
- [x] Update `vehicle-poser` env in `docker-compose.yml`: drop `MQTT_*`, keep
      `REDIS_URL`/`DATABASE_URL`, expose the HTTP port on the compose network. →
      added `HTTP_PORT: 8080` + `expose: ["8080"]`; dropped the `nanomq` depends_on.
- [x] Enable forwarding in `dev/traccar/traccar.xml`:
      `forward.type=json`, `forward.url=http://vehicle-poser:<port>/forward`
      (uncomment/replace the commented Redis block). Add retry keys as desired. →
      `forward.enable/type=json/url=http://vehicle-poser:8080/forward` +
      `forward.retry.enable=true`; `traccar` now `depends_on` `vehicle-poser`.
- [x] Verify: phone fix → Traccar → POST to shim → `redis-cli -n 1 GET
      vehicle:<username>:*` shows the correct record → `cafe-car` serves a valid
      `vehicle_positions.pb` and `trip_updates.pb` **with no cafe-car changes**. →
      **Verified through Traccar's real `:5055` osmand endpoint** (simulating the
      phone): created device `e2edriver` via REST, POSTed a fix, Traccar forwarded
      to the shim, Redis held
      `{"driver":"e2edriver","trip_id":null,"lat":...,"speed":6.1733,"timestamp":...}`
      (12 knots → 6.1733 m/s, correct contract). cafe-car reads this key unchanged;
      full `.pb` serving relies on real trip data (no cafe-car changes were needed).

**Gotchas**

- **Do NOT use `forward.type=redis`** — it `LPUSH`es raw Position JSON to
  `positions.<uniqueId>` (unbounded list, no TTL, no `trip_id`, wrong key). The
  HTTP shim is what preserves the contract.
- The old capability of encoding an explicit `trip_id` in the device slug is
  gone; every position resolves trip by schedule. If a manual override is ever
  needed, model it as a Traccar device attribute later.
- `resolve_driver_trip` returns `None` when there's no active rule or no feed
  timezone — the shim should still store the position (with `trip_id=None`), same
  as today, so vehicle_positions works even when trip_updates can't resolve.
- Traccar forwards per-position; if a driver reports faster than expected, the
  shim just overwrites the same key — fine (matches current overwrite semantics).

## Phase 3 — Manager auth & data model (keep simple)

Confirm the human-facing story without hardening. Managers log into Traccar via
Dex OIDC (already wired); drivers never log in (device-only). Document, don't
over-build.

- [x] Verify Dex OIDC login → Traccar auto-creates a regular user (PoC-verified);
      confirm managers can see the devices they need. → **Re-verified on the live
      stack.** Server flags: `registration:true`, `openIdEnabled:true`,
      `openIdForce:false`. Logging in as a brand-new Dex user (`bob@local`) through
      "Login with OpenID" auto-created a regular Traccar user. **Key finding on
      visibility: an OIDC-provisioned manager sees ZERO devices by default** —
      Traccar scopes device visibility per-user, and our fleet devices
      (`test123`, `e2edriver`) are owned by the internal `admin@local` because
      cafe-car creates them via REST as that account. Confirmed both ways: fresh
      `bob` sees no devices; `alice` (userId 2) is linked to only the one device she
      registered herself (`some-id`), not the admin-owned REST devices. So **managers
      do NOT automatically see the fleet** — see the deferred gap below.
- [x] Document the model: **Admin = us, Manager = bus company (Dex OIDC), Driver =
      device (no account)**. → documented below and in `TRACCAR_POC_FINDINGS.md`
      ("Auth & data model"). Deferred gaps recorded: (1) Dex `staticPasswords` emit
      no `groups` claim, so `openid.adminGroup` can't auto-grant admin — internal
      `admin@local` login stays the admin path; (2) **device-permission gap** —
      REST-created devices are admin-owned, so managers see nothing until devices are
      explicitly shared with them (grant `POST /api/permissions {userId, deviceId}`,
      or create devices as/assign them to the manager, or promote the manager to a
      Traccar admin). Not built now; noted for the real fleet layer.
- [x] Decide + document the `registration` flag posture (see Phase 1 gotcha). →
      **Decision: keep `registration=true`.** It is the switch OIDC needs to
      auto-provision manager users on first login; turning it off breaks the whole
      Dex-manager story. The tradeoff (it also exposes self-service account
      registration in the web UI) is acceptable in dev and behind the public
      Traccar hostname's normal protections in prod. Prod hardening path if that
      tradeoff becomes unacceptable: set `openid.force=true` to force SSO + hide the
      internal register/login form, and gate account creation at Dex. Deferred.

**Data model (documented)**

| Role | Identity | Auth | Traccar object |
|---|---|---|---|
| **Admin** (us) | `admin@local` | internal password | administrator user; owns REST-created devices |
| **Manager** (bus company) | Dex OIDC identity | Dex SSO ("Login with OpenID") | regular user, auto-provisioned on first login |
| **Driver** | device `uniqueId = username` | none (device-only, QR-provisioned) | Device, no user account |

**Gotchas**

- No native SAML in Traccar; OIDC/LDAP only — fine, we use Dex.
- `docker compose down -v` wipes the shared `db_data` volume → Traccar data +
  the `registration`/admin state reset (PoC gotcha). Note for anyone testing.

## Phase 4 — Dual-run & comparison

De-risk cutover by running both pipelines into Redis and comparing before flipping.

- [x] Run OwnTracks/vehicle-poser(old) **and** Traccar/shim concurrently. Since
      both would write `vehicle:*`, isolate: point the new shim at a **shadow key
      prefix** or shadow Redis DB, or run the shim read-only-compare, to avoid
      clobbering the live feed during comparison. → **Isolation = shadow key
      prefix** (same Redis DB 1, chosen over a shadow DB for simplicity + zero
      cafe-car impact). Added `VEHICLE_KEY_PREFIX` env to `vehicle-poser`
      (default `vehicle`; the shim now writes `{prefix}:{username}:{deviceId}`).
      `docker-compose.dualrun.yml` override sets it to `shadow:vehicle`. Safe
      because cafe-car scans `vehicle:{u}:*`, which does **not** match a
      `shadow:vehicle:...` key (the char after `vehicle` is `:` vs `_`/nothing).
      **Verified end-to-end on the live stack**: with the override, a POSTed
      Traccar forward landed at `shadow:vehicle:dualrun-test:9` and `vehicle:*`
      stayed empty; without the override the default still writes `vehicle:*`.
- [~] Compare position freshness, coordinates, and resolved `trip_id` for the same
      driver across both paths; measure QR setup time, iOS background reliability,
      and route-switch friction with a small real operator. → **Tooling built**:
      `scripts/compare_pipelines.py` (read-only) diffs live `vehicle:*` vs shadow
      `shadow:vehicle:*` per driver — reports `live_age`/`shadow_age`, `Δcoord_m`
      (haversine), and `trip_id` agreement; `--json` for machine output. Verified
      against seeded keys. **Remaining (manual, real operator)**: QR setup time,
      iOS background reliability, route-switch friction — field measurements the
      script can't produce.
- [ ] Sign-off criteria to proceed to cutover (accuracy + reliability parity).
      → **Criteria documented** (README "Dual-run comparison" + the script's
      footer): both feeds present per active driver, small `Δcoord_m`, and
      matching `trip_id` across a real route, plus acceptable iOS background
      reliability. **Actual sign-off is a human gate** on a real dual-run —
      cannot be checked off here.

**Gotchas**

- Key collision is the main hazard — decide the isolation mechanism *before*
  dual-running so the live OwnTracks feed isn't corrupted.
- iOS kills the Traccar Client on swipe-away (platform behavior) — expect "bus
  disappeared" reports; capture as an onboarding checklist item, not a blocker.

## Phase 5 — Cutover & decommission

Flip to Traccar as the source of truth and remove the OwnTracks path.

- [x] Point the shim at the real `vehicle:*` keys; make Traccar the live source.
      → **Already the default and the sole writer** — `VEHICLE_KEY_PREFIX`
      defaults to `vehicle`, and the old OwnTracks vehicle-poser subscriber was
      replaced wholesale in Phase 2, so nothing else writes `vehicle:*`. Cutover =
      running the default stack (no `docker-compose.dualrun.yml` override). No
      compose change was needed.
- [x] Remove OwnTracks-specific pieces: the old MQTT subscriber code path is
      already gone (Phase 2); remove any OwnTracks MQTT **auth** wiring that only
      served vehicle-poser (verify cafe-car MQTT auth isn't shared with
      trip-updogger/hell-gate before deleting). → **Key discovery: almost nothing
      was vehicle-poser-only.** The `owntracks/#` topic + NanoMQ ACL is *shared* —
      `hell-gate-bridge` publishes `owntracks/{amtrakdriver}/{trip_id}` and
      `trip-updogger` subscribes `owntracks/+/+` for the Amtrak feed. So the ACL
      and topic namespace **stay**. cafe-car's per-Driver entries in the NanoMQ
      `passwd` file (`passwd_file.py`) are now vestigial for position-publishing,
      but `"public":"public"` there is still required by trip-updogger, and the
      per-driver creds are harmless — left as an optional cross-repo follow-up
      rather than churn cafe-car. The only OwnTracks-specific thing in this repo
      (the vehicle-poser MQTT subscriber) was already deleted in Phase 2.
- [x] **Keep** NanoMQ (trip-updogger + hell-gate still use it). Confirm nothing
      else depended on the OwnTracks user/topic before pruning ACLs. → Confirmed
      via grep: `trip-updogger` (`owntracks/+/+` subscribe) and `hell-gate-bridge`
      (`owntracks/{username}/{trip_id}` publish) both depend on it. **No ACLs
      pruned.**
- [x] Update `README.md`, `CLAUDE.md` service map, and `vehicle-poser` README to
      reflect the HTTP-forward architecture. Retire `TRACCAR_POC_FINDINGS.md` once
      folded into real docs. → README's dual-run-migration section replaced with a
      "Vehicle locations (Traccar)" section + historical dual-run note; MQTT creds
      note corrected (drivers use Traccar, MQTT is Amtrak-internal). CLAUDE.md
      service map/app list updated (vehicle-poser = HTTP-forward, traccar = live
      source). `vehicle-poser` README was **already** on the HTTP-forward
      architecture from Phase 2 (no change). `TRACCAR_POC_FINDINGS.md` folded into
      new **`docs/traccar.md`** (architecture + auth/data model + gotchas +
      retention) and deleted.
- [x] Decide Traccar **retention** policy — Traccar persists every fix to the
      `traccar` Postgres DB; add a cleanup/retention job and size storage (this is
      new durable data we didn't keep before). → **Confirmed Traccar 6.14.5 has NO
      config-file retention key** (checked the config-file docs). Added
      `scripts/traccar_retention.sql` (default 30 days, `-v days=<n>`) that deletes
      old `tc_positions` while preserving each device's latest/motion position
      (`tc_devices.positionid`/`motionpositionid`) and event anchors
      (`tc_events.positionid`) — no DB-level FK exists in this version, but those
      references are preserved for correctness. **Verified it runs clean against
      the live `traccar` DB.** Decision: dev = manual prune (volume is wiped on
      `down -v` anyway); prod = schedule the SQL (cron/pg_cron/CronJob), which is
      Terraform scope (out of scope here). Documented in `docs/traccar.md`.

**Gotchas**

- Don't delete NanoMQ or shared MQTT auth reflexively — grep for other consumers
  first (`trip-updogger`, `hell-gate-bridge`).
- The `traccar` DB lives in the shared `db_data` volume; ensure prod backups/
  `prevent_destroy` cover it before this is real (Terraform, out of scope here).

---

## Deferred / explicitly out of scope

- **Identity hardening**: per-device tokens, TLS client certs, plausibility/
  teleport filtering, cloned-QR detection.
- **Dex groups → Traccar admin** auto-grant (needs a Dex connector emitting
  `groups`; `staticPasswords` can't).
- **Route-switch UX beyond QR**: `traccar://` deeplink (upstream, unshipped) and
  a custom branded SDK app (feasibility doc §7 Options 3–4).
- **Hardware GPS pucks** (supported by Traccar, not part of this migration).
- **Terraform-ification** of Traccar (+ DB volumes, DNS, Traefik) for prod.
