#!/usr/bin/env bash
# Wipes and rebuilds the whole local stack, then reprovisions the standard
# dev feeds. This is the "things are broken, start over" button: see
# README.md "Resetting local state" for why patching state in place (stale
# owners after an OIDC provider change, drifted Keycloak realm state, etc.)
# isn't worth it for a local-only stack.
#
# Wipes: the `db` volume (cafe-car's app DB *and* the `keycloak` DB living in
# the same Postgres instance) and the `redis` volume. Everything in them is
# gone: feeds, trackers, positions, Keycloak users/sessions.
#
# Recreates: a fresh Keycloak realm import (dev/keycloak/*.json), the
# alice@local cafe-car account, Traccar's first admin account, and the three
# default feeds (amtrak, columbia-county, west) via provision_default_feeds.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || cp .env.example .env

echo "==> down -v"
docker compose down -v

echo "==> up --build --wait"
docker compose up --build --wait

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

echo "==> bootstrap alice@local's cafe-car account"
kc_token=$(curl -sf -X POST \
  http://localhost:8090/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d grant_type=password \
  -d username=admin -d password=admin | jq -r .access_token)

alice_sub=$(curl -sf "http://localhost:8090/admin/realms/gtfs/users?username=alice" \
  -H "Authorization: Bearer $kc_token" | jq -r '.[0].id')

if [ -z "$alice_sub" ] || [ "$alice_sub" = "null" ]; then
  echo "    could not find Keycloak user 'alice' in realm 'gtfs'; aborting" >&2
  exit 1
fi

# admin runs with DEBUG=true, which makes it decode (but not verify the
# signature of) an Authorization: Bearer JWT for email/name claims: see
# cafe-car/src/cafe_car/admin/auth.py OIDCAuthBackend.authenticate(). A plain
# curl carrying alice's *real* Keycloak subject drives the same
# resolve_login() path a browser login would, without a browser or an OIDC
# flow, and using her real subject means a later real login lands on this
# same account instead of minting a duplicate.
jwt_payload=$(python3 -c "
import base64, json, sys
claims = {'sub': sys.argv[1], 'email': 'alice@local', 'email_verified': True, 'name': 'Alice Local'}
def b64(d): return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b'=').decode()
print(f\"{b64({'alg': 'none', 'typ': 'JWT'})}.{b64(claims)}.\")
" "$alice_sub")

curl -sfL http://localhost:8001/ \
  -H "X-Auth-Request-User: $alice_sub" \
  -H "Authorization: Bearer $jwt_payload" >/dev/null
echo "    alice@local ready (keycloak subject $alice_sub)"

echo "==> provisioning default feeds"
./scripts/provision_default_feeds.sh
