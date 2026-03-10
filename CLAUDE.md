# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`music-student` is the local development orchestration repo for the GTFS-RT project. It consolidates all services into a single `docker compose up --build` without requiring host.docker.internal networking hacks.

The project consists of four application repos:
- `redis-gtfs-rt-api` — FastAPI public API + admin app, Alembic migrations
- `schedule-foamer` — Celery worker + beat scheduler
- `trip-updogger` — MQTT→GTFS-RT Trip Updates bridge
- `vehicle-poser` — MQTT→Redis vehicle position bridge

## Running Locally

```bash
cp .env.example .env
docker compose up --build
```

## Environment Variable System

`.env` (gitignored, copy from `.env.example`) controls two things:

**Build context paths** — where to find local repo checkouts:
```
REDIS_GTFS_RT_API_DIR=../redis-gtfs-rt-api
SCHEDULE_FOAMER_DIR=../schedule-foamer
TRIP_UPDOGGER_DIR=../trip-updogger
VEHICLE_POSER_DIR=../vehicle-poser
```

**Image overrides** — optional, to pull from a registry instead of building:
```
REDIS_GTFS_RT_API_IMAGE=ghcr.io/org/redis-gtfs-rt-api:latest
```

## Remote Image Workflow

To use a registry image instead of building locally, set the `_IMAGE` variable and pull:
```bash
docker compose pull api migrate admin
```
Leave the variable unset to build from the local `_DIR` path (default behavior).

## Service Map

| Service | Port | Description |
|---|---|---|
| db | 5432 | PostgreSQL 16 |
| redis | 6379 | Redis 7 |
| migrate | — | Runs `alembic upgrade head`, exits |
| api | 8000 | GTFS-RT public API |
| admin | 8001 | SQLAdmin interface (direct, no auth) |
| celery-worker | — | Schedule-foamer Celery worker |
| celery-beat | — | Schedule-foamer Celery beat scheduler |
| nanomq | 1883 | MQTT broker (auth delegated to api) |
| dex | 5556 | OIDC provider (static dev users) |
| oauth2-proxy | 4180 | oauth2-proxy in front of admin |
| trip-updogger | — | MQTT→GTFS-RT Trip Updates bridge |
| vehicle-poser | — | MQTT→Redis vehicle position bridge |

## Redis DB Allocation

- DB 0: oauth2-proxy session storage
- DB 1: api + trip-updogger + vehicle-poser (vehicle position data)
- DB 3: Celery broker (schedule-foamer tasks)
- DB 4: Celery result backend
