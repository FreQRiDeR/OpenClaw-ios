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
    # Fall back to reading the token from the OpenClaw config file.
    # NOTE: `openclaw config get gateway.auth.token` redacts secrets on some
    # systems (returns __OPENCLAW_REDACTED__), so parse the file directly.
    if [ -f "$HOME/.openclaw/openclaw.json" ]; then
        OPENCLAW_GATEWAY_TOKEN=$(python3 -c "import json,sys; print(json.load(open('$HOME/.openclaw/openclaw.json')).get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
    fi
fi
# Must export so the child python3 process inherits it
export OPENCLAW_GATEWAY_TOKEN
if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "ERROR: OPENCLAW_GATEWAY_TOKEN is not set"
    exit 1
fi

if [ "$OPENCLAW_GATEWAY_TOKEN" = "__OPENCLAW_REDACTED__" ]; then
    echo "ERROR: token is the redacted placeholder — unset OPENCLAW_GATEWAY_TOKEN and let this script read ~/.openclaw/openclaw.json"
    exit 1
fi

PORT="${STATS_SERVER_PORT:-8765}"

echo "Starting stats server..."
nohup python3 "$STATS_SERVER_PY" >> /tmp/stats_server.log 2>&1 &

# Startup runs `openclaw config get` to resolve the workspace, which can take
# several seconds — wait for the port instead of a fixed sleep.
HTTP=000
for _ in $(seq 1 20); do
    sleep 0.5
    if ! pgrep -f stats_server.py > /dev/null; then
        echo "ERROR: Stats server exited during startup — last log lines:"
        tail -5 /tmp/stats_server.log
        exit 1
    fi
    # Verify it actually answers with the token it was given (catches wrong-token / port-in-use)
    HTTP=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OPENCLAW_GATEWAY_TOKEN" "http://127.0.0.1:$PORT/stats/health" 2>/dev/null)
    [ "$HTTP" = "200" ] && break
done
if [ "$HTTP" = "200" ]; then
    echo "Stats server started OK (PID: $(pgrep -f stats_server.py), http://127.0.0.1:$PORT/stats/health -> 200)"
else
    echo "WARNING: process is running but /stats/health returned HTTP ${HTTP:-000} — check /tmp/stats_server.log"
    exit 1
fi