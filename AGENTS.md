# AGENTS.md

Local development stack for the gtfs.zone realtime services: one
`docker compose up --build` over sibling checkouts of rt-api, static-importer,
rt-traccar-receiver, rt-delay-estimator, rt-pollers and rt-manager. Nothing
deploys from here; production is gtfs-zone-infra.

## Commands

```bash
scripts/reset.sh   # wipe every volume, rebuild, reprovision the dev feeds
```

## Architecture

`docker-compose.yml` is the whole stack. Ports, credentials, build contexts,
Postgres roles, Redis DBs and the Keycloak setup are in [README.md](README.md);
first-run steps are in [startup-guide.md](startup-guide.md); Traccar is in
[docs/traccar.md](docs/traccar.md).

- **Mirror prod**: one Postgres role and database per service, like the CNPG
  topology. `dev/postgres/init-roles.sql` only runs on an empty `db` volume,
  so a role change needs a reset.
- **`:4180` is the one authenticated edge**: oauth2-proxy path-routes between
  rt-manager and the admin app, standing in for Traefik. Anything auth-shaped is
  tested there, never against a port that skips the proxy.
- **Producers post over HTTP**: trip updates and positions reach rt-api's
  `/ingest/*` routes or Redis directly. There is no MQTT broker.
  `rt-delay-estimator` is a Redis-to-Redis fallback that never overwrites a
  richer producer's record.
- No `host.docker.internal`: every service reaches the others by compose name.

## Conventions

- **Commits**: Conventional Commits, enforced by the `commit-msg` hook. Never add
  Co-Authored-By trailers. Setup and release are in [CONTRIBUTING.md](CONTRIBUTING.md).
- **Plans**: write plans to `CURRENT_PLAN.md` at the repo root as a
  checklist (`- [ ]`), ticked off as work lands. It is neither tracked nor
  gitignored: never stage or commit it.
