# music-student

Local development environment for the GTFS-RT project. Runs all services with a single command.

## Quickstart

1. Clone all repos as siblings:
   ```bash
   git clone <redis-gtfs-rt-api>
   git clone <schedule-foamer>
   git clone <trip-updogger>
   git clone <vehicle-poser>
   git clone <music-student>
   ```

2. Copy the example env file:
   ```bash
   cd music-student
   cp .env.example .env
   ```

3. Start everything:
   ```bash
   docker compose up --build
   ```

## Port Map

| Port | Service |
|------|---------|
| 5432 | PostgreSQL |
| 6379 | Redis |
| 8000 | GTFS-RT public API |
| 8001 | Admin app (direct, no auth) |
| 1883 | MQTT broker (NanoMQ) |
| 4180 | Admin app via oauth2-proxy |
| 5556 | Dex OIDC provider |

## Dev Credentials

**Admin login** (via http://localhost:4180):
- alice / password
- bob / password

**PostgreSQL**: `postgres` / `mysecretpassword`

**MQTT**: any Driver username/password configured in the admin app.
