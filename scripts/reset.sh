#!/usr/bin/env bash
# Wipes and rebuilds the whole local stack, then reprovisions the standard
# dev feeds. This is the "things are broken, start over" button: see
# README.md "Resetting local state" for why patching state in place (stale
# owners after an OIDC provider change, drifted Keycloak realm state, etc.)
# isn't worth it for a local-only stack.
#
# Wipes: the `db` volume (rt-api's app DB *and* the `keycloak` DB living in
# the same Postgres instance), the `redis` volume, and Garage's `garage_meta`
# and `garage_data` volumes. Everything in them is gone: feeds, trackers,
# positions, Keycloak users/sessions, and every uploaded GTFS zip.
#
# Recreates: a fresh Keycloak realm import (dev/keycloak/*.json), Traccar's
# break-glass admin account, and the west feed via provision_default_feeds.sh.
# alice@local's rt-api account and the amtrak / columbia-county feeds come
# up with the stack now, from the `seed` service in docker-compose.yml. So does
# Garage's layout, bucket and access key, from `garage-init`: an empty Garage
# rejects every write with a 500 that never mentions layouts, so that is a
# service the apps depend on rather than a step anybody has to remember.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || cp .env.example .env

echo "==> down -v"
docker compose down -v

echo "==> up --build --wait"
docker compose up --build --wait

echo "==> waiting for Traccar"
# traccar has no healthcheck, so `up --wait` returns the moment the container
# is running - well before the JVM is accepting HTTP. Without this the POST
# below fails with curl 56 and takes the whole script down under `set -e`.
for _ in $(seq 1 60); do
  curl -sf -o /dev/null http://localhost:8082/api/server && break
  sleep 2
done

echo "==> bootstrap Traccar admin"
existing_admin=$(docker compose exec -T db psql -U postgres -d traccar -tAc \
  "select count(*) from tc_users where administrator = true;")
if [ "${existing_admin:-0}" -eq 0 ]; then
  curl -sf -X POST http://localhost:8082/api/users \
    -H 'Content-Type: application/json' \
    -d '{"name":"Admin","email":"admin@local","password":"admin"}' >/dev/null
  echo "    created admin@local / admin"
else
  echo "    already present, skipping"
fi

echo "==> disabling Traccar self-registration"
# Prod keeps this off so the public sign-up form cannot bypass the
# openid.allowGroup gate; openid.allowRegistration is what still lets a
# gtfs-admins member provision themselves on first OIDC login.
docker compose exec -T db psql -U postgres -d traccar -qtAc \
  "update tc_servers set registration = false;" >/dev/null

echo "==> provisioning the west feed"
./scripts/provision_default_feeds.sh
