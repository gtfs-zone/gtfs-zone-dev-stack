# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`music-student` is the local development orchestration repo for the GTFS-RT project. It consolidates all services into a single `docker compose up --build` without requiring host.docker.internal networking hacks.

The project consists of these application repos:
- `railroad-club`: shared SQLModel models + Alembic migrations
- `cafe-car`: FastAPI public API + admin app (also hosts the `/ingest/*` seam)
- `schedule-foamer`: Celery worker + beat scheduler
- `vehicle-poser`: Traccar HTTP-forward→Redis vehicle position bridge
- `hell-gate-bridge`: Amtrak live tracker→cafe-car ingest (positions + trip-updates)
- `trip-updogger`: Redis→Redis worker: schedule-derived Trip Updates for positions
  that arrive without predictions of their own (chiefly the Traccar path)

The NanoMQ broker was retired in Phase 7; trip-updates now come straight from
producers over HTTP, and `trip-updogger` (once an MQTT bridge) was rebuilt as a
Redis→Redis fallback that never overwrites a richer producer's record.

## Running Locally

```bash
cp .env.example .env
docker compose up --build
```

## Environment Variable System

`.env` (gitignored, copy from `.env.example`) controls two things:

**Build context paths**: where to find local repo checkouts:
```
CAFE_CAR_DIR=../cafe-car
SCHEDULE_FOAMER_DIR=../schedule-foamer
TRIP_UPDOGGER_DIR=../trip-updogger
VEHICLE_POSER_DIR=../vehicle-poser
```

**Image overrides**: optional, to pull from a registry instead of building:
```
CAFE_CAR_IMAGE=ghcr.io/org/cafe-car:latest
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
| migrate | - | Runs `alembic upgrade head`, exits |
| api | 8000 | GTFS-RT public API |
| admin | 8001 | SQLAdmin interface (direct, no auth) |
| celery-worker | - | Schedule-foamer Celery worker |
| celery-beat | - | Schedule-foamer Celery beat scheduler |
| flower | 5555 | Celery monitoring web UI |
| keycloak | 8090 | OIDC provider (dev users + `fake-github`/`fake-google` broker realms). Needs a `keycloak` → 127.0.0.1 `/etc/hosts` entry |
| keycloak-db-init | - | Creates the `keycloak` database in Postgres, exits |
| mailpit | 8025 | Catches dev mail (Keycloak account-link verification) |
| dex | 5556 | Legacy OIDC provider (Traccar only, retained until the prod cutover) |
| oauth2-proxy | 4180 | oauth2-proxy in front of admin |
| vehicle-poser | 8080 (internal) | Traccar `json` HTTP-forward receiver→Redis vehicle position bridge |
| trip-updogger | - | Redis→Redis worker: schedule-derived trip updates for positions with no predictions |
| hell-gate-bridge | - | Amtrak live tracker→cafe-car `/ingest/*` (positions + trip-updates) |
| traccar-db-init | - | Creates the `traccar` database in Postgres, exits |
| traccar | 8082, 5055 | Traccar GPS tracking server, live vehicle-location source (8082 = web/REST, 5055 = phone client protocol). See `docs/traccar.md` |

## Redis DB Allocation

- DB 0: oauth2-proxy session storage
- DB 1: api + vehicle-poser + trip-updogger (vehicle position + trip-update data)
- DB 3: Celery broker (schedule-foamer tasks)
- DB 4: Celery result backend

## Forgejo Workflow

This project uses an offline-first workflow. Claude reads/writes `CURRENT_PLAN.md` locally and only touches Forgejo when explicitly asked.

### Making a plan (triggered by "make a plan for issue #N" or "let's plan X")

1. If the user said "fetch issue #N", use `mcp__forgejo__get_issue_by_index` with `owner: "gtfs.zone"`, `repo: "deploy-gtfs-rt"` to retrieve the issue body; otherwise work from the context provided
2. Explore the codebase as needed
3. Ask clarifying questions inline; wait for answers before writing
4. Write the plan to `CURRENT_PLAN.md` in the repo root (format: Summary, Relevant Context, numbered Phases each with prose + checklist + gotchas)
5. Do not start implementation

### Completing a phase (triggered by "complete phase N" or "do phase N")

1. Read `CURRENT_PLAN.md` directly, do not fetch from Forgejo
2. Implement everything in the phase; commit as you go with conventional commits
3. After completing, update `CURRENT_PLAN.md`: check off completed items, append discoveries to that phase's prose
4. Do not update the Forgejo issue; do not start the next phase; stop for user review

### Updating Forgejo (triggered by "update issue #N")

1. Use `mcp__forgejo__update_issue` to overwrite the issue body with the current contents of `CURRENT_PLAN.md`

### Creating a PR (triggered by "make a PR closing #N")

1. Use `mcp__forgejo__create_pull_request` with `owner: "gtfs.zone"`, `repo: "deploy-gtfs-rt"`, current branch as `head`, `main` as `base`, issue title as PR title, `Closes #N` as body

## Rules

- Never add `Co-Authored-By: Claude ...` trailers to commit messages.
