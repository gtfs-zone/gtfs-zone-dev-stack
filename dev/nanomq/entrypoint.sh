#!/bin/sh
set -e

PASSWD_FILE=/run/nanomq/passwd
NANOMQ=/usr/local/nanomq/nanomq
POLL_INTERVAL=5

start_nanomq() {
    "$NANOMQ" start &
    NANOMQ_PID=$!
    echo "[entrypoint] NanoMQ started (pid=$NANOMQ_PID)"
}

handle_term() {
    kill "$NANOMQ_PID" 2>/dev/null || true
    wait "$NANOMQ_PID" 2>/dev/null || true
    exit 0
}
trap handle_term TERM INT

sleep 3
start_nanomq

LAST_SUM=$(md5sum "$PASSWD_FILE" 2>/dev/null | cut -d' ' -f1 || echo "")

while true; do
    sleep "$POLL_INTERVAL" &
    wait $!

    CURRENT_SUM=$(md5sum "$PASSWD_FILE" 2>/dev/null | cut -d' ' -f1 || echo "")

    if [ "$CURRENT_SUM" != "$LAST_SUM" ]; then
        echo "[entrypoint] passwd changed, restarting NanoMQ"
        kill "$NANOMQ_PID" 2>/dev/null || true
        wait "$NANOMQ_PID" 2>/dev/null || true
        start_nanomq
        LAST_SUM=$CURRENT_SUM
    elif ! kill -0 "$NANOMQ_PID" 2>/dev/null; then
        echo "[entrypoint] NanoMQ crashed, restarting"
        start_nanomq
    fi
done
