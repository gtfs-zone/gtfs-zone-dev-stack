#!/usr/bin/env python3
"""Phase 4 dual-run comparison: diff the live vs shadow vehicle-position feeds.

During cutover de-risking we run two pipelines into the same Redis DB:

  * live   : OwnTracks -> rt-traccar-receiver(old) -> ``vehicle:{user}:{device}``
  * shadow : Traccar   -> shim (VEHICLE_KEY_PREFIX=shadow:vehicle)
             -> ``shadow:vehicle:{user}:{device}``

This script reads both namespaces and, per driver, reports position freshness,
coordinate delta, and resolved ``trip_id`` agreement so a human can judge parity
before flipping rt-api onto the Traccar feed. It is read-only; it never writes
to Redis.

Usage:
    REDIS_URL=redis://localhost:6379/1 python scripts/compare_pipelines.py
    python scripts/compare_pipelines.py --redis-url redis://localhost:6379/1 \
        --live-prefix vehicle --shadow-prefix shadow:vehicle --json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from dataclasses import dataclass, field

try:
    import redis
except ImportError:  # pragma: no cover - dependency hint
    sys.exit("This script needs the 'redis' package: pip install redis")


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in metres between two lat/lon points."""
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _scan(client: redis.Redis, prefix: str) -> dict[str, dict]:
    """Return {username: record} for the freshest key under a prefix.

    Keys look like ``{prefix}:{username}:{device}``; if a driver has several
    device keys we keep the one with the newest timestamp.
    """
    out: dict[str, dict] = {}
    for key in client.scan_iter(f"{prefix}:*"):
        key_s = key.decode() if isinstance(key, bytes) else key
        rest = key_s[len(prefix) + 1 :]
        username = rest.split(":", 1)[0]
        raw = client.get(key_s)
        if raw is None:
            continue
        try:
            rec = json.loads(raw)
        except (ValueError, TypeError):
            continue
        prev = out.get(username)
        if prev is None or (rec.get("timestamp") or 0) >= (prev.get("timestamp") or 0):
            out[username] = rec
    return out


@dataclass
class DriverComparison:
    username: str
    live: dict | None
    shadow: dict | None
    coord_delta_m: float | None = None
    trip_id_match: bool | None = None
    notes: list[str] = field(default_factory=list)


def compare(
    live: dict[str, dict], shadow: dict[str, dict], now: float
) -> list[DriverComparison]:
    rows: list[DriverComparison] = []
    for username in sorted(set(live) | set(shadow)):
        lv, sh = live.get(username), shadow.get(username)
        row = DriverComparison(username=username, live=lv, shadow=sh)
        if lv is None:
            row.notes.append("missing from LIVE (OwnTracks)")
        if sh is None:
            row.notes.append("missing from SHADOW (Traccar)")
        if lv and sh:
            try:
                row.coord_delta_m = _haversine_m(
                    lv["lat"], lv["lon"], sh["lat"], sh["lon"]
                )
            except (KeyError, TypeError):
                row.notes.append("could not compute coord delta")
            row.trip_id_match = lv.get("trip_id") == sh.get("trip_id")
            if not row.trip_id_match:
                row.notes.append(
                    f"trip_id differs: live={lv.get('trip_id')!r} "
                    f"shadow={sh.get('trip_id')!r}"
                )
        rows.append(row)
    return rows


def _age(rec: dict | None, now: float) -> str:
    if not rec or rec.get("timestamp") is None:
        return "-"
    return f"{now - rec['timestamp']:.0f}s"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--redis-url",
        default=os.environ.get("REDIS_URL", "redis://localhost:6379/1"),
    )
    ap.add_argument("--live-prefix", default="vehicle")
    ap.add_argument("--shadow-prefix", default="shadow:vehicle")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = ap.parse_args()

    client = redis.from_url(args.redis_url)
    now = time.time()
    live = _scan(client, args.live_prefix)
    shadow = _scan(client, args.shadow_prefix)
    rows = compare(live, shadow, now)

    if args.json:
        print(
            json.dumps(
                [
                    {
                        "username": r.username,
                        "live": r.live,
                        "shadow": r.shadow,
                        "coord_delta_m": r.coord_delta_m,
                        "trip_id_match": r.trip_id_match,
                        "notes": r.notes,
                    }
                    for r in rows
                ],
                indent=2,
            )
        )
        return 0

    if not rows:
        print(
            f"No keys found under '{args.live_prefix}:*' or "
            f"'{args.shadow_prefix}:*'."
        )
        return 0

    print(
        f"{'driver':<16} {'live_age':>9} {'shadow_age':>10} "
        f"{'Δcoord_m':>9} {'trip=':>6}  notes"
    )
    print("-" * 78)
    mismatches = 0
    for r in rows:
        delta = f"{r.coord_delta_m:.1f}" if r.coord_delta_m is not None else "-"
        trip = {True: "yes", False: "NO", None: "-"}[r.trip_id_match]
        if r.notes or r.trip_id_match is False:
            mismatches += 1
        print(
            f"{r.username:<16} {_age(r.live, now):>9} {_age(r.shadow, now):>10} "
            f"{delta:>9} {trip:>6}  {'; '.join(r.notes)}"
        )
    print("-" * 78)
    print(
        f"{len(rows)} driver(s); {mismatches} with mismatches/gaps. "
        "Aim for both feeds present, small Δcoord, matching trip_id before cutover."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
