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
    # Fall back to the gateway token from the OpenClaw config (not exported by the service env)
    OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
    if [ -f "$OPENCLAW_CONFIG" ] && command -v python3 > /dev/null; then
        OPENCLAW_GATEWAY_TOKEN=$(python3 -c "import json; c=json.load(open('$OPENCLAW_CONFIG')); print(c.get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
    fi
fi

if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "ERROR: OPENCLAW_GATEWAY_TOKEN is not set and no gateway token found in ~/.openclaw/openclaw.json"
    exit 1
fi
export OPENCLAW_GATEWAY_TOKEN

echo "Starting stats server..."
nohup python3 "$STATS_SERVER_PY" >> /tmp/stats_server.log 2>&1 &
sleep 1
if pgrep -f stats_server.py > /dev/null; then
    echo "Stats server started OK (PID: $(pgrep -f stats_server.py))"
else
    echo "ERROR: Stats server failed to start"
    exit 1
fi
