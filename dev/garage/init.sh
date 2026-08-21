#!/bin/sh
# Bring a fresh Garage node to the point where it will accept a write: assign
# the layout, create the bucket, and import the fixed dev access key.
#
# Garage refuses every S3 call until a layout is applied, with a 500 that says
# nothing about layouts, so this has to run before anything uploads. Each step
# checks first: `docker compose up` runs this on every start, and applying a
# layout twice is not a no-op.
set -eu

BUCKET="${S3_BUCKET:-gtfs-feeds}"
KEY_NAME="${GARAGE_KEY_NAME:-dev}"
ACCESS_KEY="${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
SECRET_KEY="${S3_SECRET_KEY:?S3_SECRET_KEY is required}"

garage() { /usr/local/bin/garage -c /etc/garage.toml "$@"; }

echo "==> waiting for the garage node"
i=0
until garage status >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "garage never answered"; exit 1; }
  sleep 1
done

# `layout show` prints the staged and applied roles. A node with no role at all
# is the only case that needs assigning; re-assigning a node that already has
# one stages a change that never gets applied and confuses `layout show`
# forever after.
if garage layout show | grep -q "No nodes currently have a role"; then
  echo "==> assigning the layout"
  node_id=$(garage status -j | jq -r '.nodes[0].id')
  garage layout assign -z dc1 -c 10G "$node_id"
  # Applying always bumps to the next version; asking for the current one
  # errors, so the target is read back rather than assumed to be 1.
  version=$(garage layout show | sed -n 's/.*--version \([0-9]*\).*/\1/p' | tail -1)
  garage layout apply --version "${version:-1}"
else
  echo "==> layout already applied"
fi

if garage bucket list | grep -q "[[:space:]]${BUCKET}[[:space:]]"; then
  echo "==> bucket ${BUCKET} already exists"
else
  echo "==> creating bucket ${BUCKET}"
  garage bucket create "$BUCKET"
fi

# Imported rather than created, because a created key is random and the apps
# read theirs from .env. Import is how a key with a known id gets in.
if garage key info "$ACCESS_KEY" >/dev/null 2>&1; then
  echo "==> key ${KEY_NAME} already imported"
else
  echo "==> importing key ${KEY_NAME}"
  garage key import -n "$KEY_NAME" --yes "$ACCESS_KEY" "$SECRET_KEY"
fi

echo "==> granting ${KEY_NAME} read/write on ${BUCKET}"
garage bucket allow --read --write "$BUCKET" --key "$ACCESS_KEY"

echo "==> garage is ready"
