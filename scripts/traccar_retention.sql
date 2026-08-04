-- Traccar position-history retention.
--
-- Traccar has NO built-in retention config key (verified against 6.14.5): it
-- persists every fix to tc_positions forever. Since the Traccar → vehicle-poser
-- migration (see docs/traccar.md) this is new durable data we didn't keep under
-- OwnTracks, so it needs pruning.
--
-- Run against the `traccar` database. `days` defaults to 30; override with
-- `-v days=<n>`:
--
--   docker compose exec -T db \
--     psql -U postgres -d traccar -v days=30 -f - < scripts/traccar_retention.sql
--
-- For prod, schedule this (cron / pg_cron / a k8s CronJob). A running cron
-- service is intentionally NOT added to the dev compose stack: see
-- docs/traccar.md "Retention".
--
-- Safety: tc_positions has no DB-level FK in 6.14.5, but tc_devices
-- (positionid, motionpositionid) and tc_events (positionid) reference position
-- rows as "latest known" / event anchors. Deleting those would strand a
-- device's last-known position, so they are explicitly preserved below.

\set days 30

BEGIN;

DELETE FROM tc_positions p
WHERE p.fixtime < now() - make_interval(days => :days)
  AND p.id NOT IN (SELECT positionid       FROM tc_devices WHERE positionid       IS NOT NULL)
  AND p.id NOT IN (SELECT motionpositionid FROM tc_devices WHERE motionpositionid IS NOT NULL)
  AND p.id NOT IN (SELECT positionid       FROM tc_events  WHERE positionid       IS NOT NULL);

COMMIT;
