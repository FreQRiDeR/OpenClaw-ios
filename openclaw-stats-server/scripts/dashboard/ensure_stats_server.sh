#!/bin/bash
# Ensure stats server is running — call this on startup or from cron
# Pass --force to kill and restart even if already running
FORCE=0
if [ "$1" = "--force" ]; then
    FORCE=1
fi

if pgrep -f stats_server.py > /dev/null; then
    if [ "$FORCE" = "1" ]; then
        echo "Force-restarting stats server..."
        pkill -f stats_server.py
        sleep 1
    else
        echo "Stats server already running (PID: $(pgrep -f stats_server.py))"
        exit 0
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATS_SERVER_PY="$SCRIPT_DIR/stats_server.py"

if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "ERROR: OPENCLAW_GATEWAY_TOKEN is not set"
    exit 1
fi

echo "Starting stats server..."
nohup python3 "$STATS_SERVER_PY" >> /tmp/stats_server.log 2>&1 &
sleep 1
if pgrep -f stats_server.py > /dev/null; then
    echo "Stats server started OK (PID: $(pgrep -f stats_server.py))"
else
    echo "ERROR: Stats server failed to start"
    exit 1
fi
