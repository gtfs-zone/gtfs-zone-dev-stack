#!/usr/bin/env bash
# Provisions the three feeds the rest of the dev stack expects to exist:
# amtrak, columbia-county (fed by hell-gate-bridge's pollers — their fixed
# INGEST_VEHICLE_ID in docker-compose.yml must match the --tracker-id here),
# and west (a real Traccar device, given a rule so a simulated/real fix always
# resolves to a trip). Mirrors startup-guide.md §4.
#
# Runs from a host checkout of cafe-car (the running api/admin containers
# don't include scripts/ or uv), against the stack's published ports. Owner
# defaults to alice@local, whose User row must already exist (see reset.sh,
# which creates it before calling this script).
#
# Idempotent: re-running reuses existing feeds/trackers by name and replaces
# west's rules.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && . .env
CAFE_CAR_DIR=${CAFE_CAR_DIR:-../cafe-car}

export TRACCAR_URL=http://localhost:8082
export TRACCAR_EMAIL=admin@local
export TRACCAR_PASSWORD=admin

cd "$CAFE_CAR_DIR"

echo "==> amtrak"
uv run python scripts/provision_source.py \
  --feed-name amtrak \
  --static-feed-url https://content.amtrak.com/content/gtfs/GTFS.zip \
  --nickname "Amtrak" \
  --tracker-id amtrak-live \
  --skip-traccar

echo "==> columbia-county"
uv run python scripts/provision_source.py \
  --feed-name columbia-county \
  --static-feed-url https://raw.githubusercontent.com/columbia-county-ny-transit/gtfs-generator/refs/heads/main/columbia_county_gtfs.zip \
  --nickname "Columbia County" \
  --tracker-id columbia-county \
  --skip-traccar

echo "==> west"
uv run python scripts/provision_source.py \
  --feed-name west \
  --static-feed-url http://westbusservice.com/west_gtfs.zip \
  --nickname "West Coastal Connection" \
  --rule daily=00:00-23:59=WCCWB

echo
echo "Done. Smoke test:"
echo "  curl -s -o /dev/null -w 'amtrak: %{http_code}\n' http://localhost:8000/amtrak/vehicle_positions.pb"
echo "  curl -s -o /dev/null -w 'columbia-county: %{http_code}\n' http://localhost:8000/columbia-county/vehicle_positions.pb"
echo "  curl -s -o /dev/null -w 'west: %{http_code}\n' http://localhost:8000/west/vehicle_positions.pb"
