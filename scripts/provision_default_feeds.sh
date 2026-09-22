#!/usr/bin/env bash
# Provisions the one feed the `seed` container cannot: west, a real Traccar
# device given a rule so a simulated or real fix always resolves to a trip.
# Schedule rules and Traccar device creation are both host concerns, which is
# what keeps this script around. Mirrors startup-guide.md §4.
#
# amtrak and columbia-county are no longer here. They are created by the `seed`
# service on `docker compose up`, which is also what pins their Tracker.id to
# the INGEST_TRACKER_ID literals the hell-gate-bridge pollers are configured
# with.
#
# Runs from a host checkout of cafe-car (the running api/admin containers
# don't include scripts/ or uv), against the stack's published ports. Owner
# defaults to alice@local, whose User row the `seed` service creates.
#
# Idempotent: re-running reuses west's feed/tracker by name and replaces its
# rules.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && . .env
CAFE_CAR_DIR=${CAFE_CAR_DIR:-../cafe-car}

# Everything points at the stack's published ports: this runs on the host, so
# the in-container hostnames (db, traccar) do not resolve. Settings has no
# defaults for these three and cafe-car has no .env of its own.
export DATABASE_URL=postgresql+asyncpg://rt_api:rt_api@localhost:5432/rt_api
export REDIS_URL=redis://localhost:6379/1
export SESSION_SECRET_KEY=dev-secret-key
export TRACCAR_URL=http://localhost:8082
export TRACCAR_EMAIL=admin@local
export TRACCAR_PASSWORD=admin

cd "$CAFE_CAR_DIR"

echo "==> west"
uv run python scripts/provision_source.py \
  --feed-name west \
  --static-feed-url http://westbusservice.com/west_gtfs.zip \
  --nickname "West Coastal Connection" \
  --rule daily=00:00-23:59=WCCWB

echo
echo "Done. Smoke test:"
echo "  curl -s -o /dev/null -w 'west: %{http_code}\n' http://localhost:8000/west/vehicle_positions.pb"
