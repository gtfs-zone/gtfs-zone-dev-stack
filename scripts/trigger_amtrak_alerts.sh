#!/usr/bin/env bash
# Force a single amtrak.com alerts scrape+sync cycle right now, instead of
# waiting for hell-gate-bridge's 30-minute ALERTS_POLL_INTERVAL loop.
set -euo pipefail

docker compose exec hell-gate-bridge python -c "
import asyncio, httpx
from hell_gate_bridge.config import Config
from hell_gate_bridge.sources.amtrak import AmtrakSource
from hell_gate_bridge.sources.amtrak.alerts import build_alerts, fetch_alert_html
from hell_gate_bridge.publisher import publish_alerts

async def main():
    config = Config()
    source = AmtrakSource(config)
    async with httpx.AsyncClient(timeout=config.http_timeout) as http:
        await source.startup(http)
        html = await fetch_alert_html(http)
        alerts = await build_alerts(html, source.resolver, config.amtrak_agency_id, http)
        count = await publish_alerts(config, http, alerts)
        print(f'{len(alerts)} scraped -> {count} synced')

asyncio.run(main())
"
