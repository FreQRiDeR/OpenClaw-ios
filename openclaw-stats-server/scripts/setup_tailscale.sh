#!/bin/bash
# One-shot setup + verification for exposing OpenClaw + the stats server over Tailscale.
#
#   https://<host>.<tailnet>.ts.net/        -> gateway   (127.0.0.1:18789)
#   https://<host>.<tailnet>.ts.net/stats/* -> stats srv (127.0.0.1:8765)
#   https://<host>.<tailnet>.ts.net/wa/*    -> stats srv (WhatsApp webhook, optional)
#
# The iOS app uses ONE base URL for everything, so the proxy MUST split paths.
# If only "/" is mapped, /stats/* hits the gateway and the app shows
# "couldn't be read because it isn't in the correct format" (HTML) or "HTTP 404".
#
# Usage:  bash setup_tailscale.sh            # configure + verify
#         bash setup_tailscale.sh --verify   # verify only, change nothing
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
STATS_PORT="${STATS_SERVER_PORT:-8765}"
VERIFY_ONLY=0; [ "${1:-}" = "--verify" ] && VERIFY_ONLY=1

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=1; }
FAIL=0

TS=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
[ -x "$TS" ] || { echo "tailscale CLI not found"; exit 1; }

# --- token (read from file: `openclaw config get` may return __OPENCLAW_REDACTED__) ---
TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
if [ -z "$TOKEN" ] || [ "$TOKEN" = "__OPENCLAW_REDACTED__" ]; then
  TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.openclaw/openclaw.json'))).get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
fi
[ -n "$TOKEN" ] || { echo "Could not read gateway token from ~/.openclaw/openclaw.json"; exit 1; }
export OPENCLAW_GATEWAY_TOKEN="$TOKEN"

echo "== 1. Local services"
if lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then ok "gateway listening on :$GATEWAY_PORT"; else bad "gateway NOT listening on :$GATEWAY_PORT (run: openclaw gateway start)"; fi
if ! lsof -nP -iTCP:"$STATS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  if [ $VERIFY_ONLY = 1 ]; then bad "stats server NOT listening on :$STATS_PORT"; else
    echo "  starting stats server…"; bash "$SCRIPT_DIR/dashboard/ensure_stats_server.sh" >/dev/null || bad "stats server failed to start (see /tmp/stats_server.log)"
  fi
fi
lsof -nP -iTCP:"$STATS_PORT" -sTCP:LISTEN >/dev/null 2>&1 && ok "stats server listening on :$STATS_PORT"

echo "== 2. Tailscale serve routing"
if [ $VERIFY_ONLY = 0 ]; then
  "$TS" serve --bg --set-path /      "http://127.0.0.1:$GATEWAY_PORT"     >/dev/null 2>&1
  "$TS" serve --bg --set-path /stats "http://127.0.0.1:$STATS_PORT/stats" >/dev/null 2>&1
  "$TS" serve --bg --set-path /wa    "http://127.0.0.1:$STATS_PORT/wa"    >/dev/null 2>&1
fi
STATUS=$("$TS" serve status 2>/dev/null)
echo "$STATUS" | grep -qE "^\|-- /\s+proxy http://127.0.0.1:$GATEWAY_PORT" && ok "/       -> :$GATEWAY_PORT" || bad "/ is not proxied to :$GATEWAY_PORT"
echo "$STATUS" | grep -qE "^\|-- /stats\s+proxy http://127.0.0.1:$STATS_PORT" && ok "/stats  -> :$STATS_PORT" || bad "/stats is not proxied to :$STATS_PORT"
HOST=$(echo "$STATUS" | grep -oE 'https://[^ ]+' | head -1)
[ -n "$HOST" ] || { bad "tailscale serve is not enabled"; echo; exit 1; }

echo "== 3. End-to-end through $HOST"
probe() { # $1=label $2=method $3=path $4=body $5=expect-substring
  local out code
  if [ "$2" = GET ]; then
    out=$(curl -s -m 20 -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$HOST$3")
  else
    out=$(curl -s -m 20 -w '\n%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$4" "$HOST$3")
  fi
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [ "$code" = 200 ] && printf '%s' "$body" | grep -q "$5"; then ok "$1"; else
    bad "$1 -> HTTP $code: $(printf '%s' "$body" | head -c 120 | tr '\n' ' ')"
    printf '%s' "$body" | grep -qi '<!doctype html' && echo "      ↳ got the gateway web UI: /stats is being routed to the gateway, not :$STATS_PORT"
  fi
}
probe "GET  /stats/health"            GET  /stats/health "" '"ok": true'
probe "GET  /stats/system"            GET  /stats/system "" 'cpu_percent'
probe "GET  /stats/tokens"            GET  "/stats/tokens?period=today" "" 'totals'
probe "POST /stats/exec skills-list"  POST /stats/exec '{"command":"skills-list"}' '"exit_code": 0'
probe "POST /stats/exec memory-list"  POST /stats/exec '{"command":"memory-list"}' '"exit_code": 0'
probe "POST /stats/exec mcp-list"     POST /stats/exec '{"command":"mcp-list"}' '"exit_code"'
probe "POST /tools/invoke sessions"   POST /tools/invoke '{"tool":"sessions_list","args":{"limit":1}}' '"ok":true'
probe "POST /tools/invoke cron"       POST /tools/invoke '{"tool":"cron","args":{"action":"list"}}' '"ok":true'

echo "== 4. Agent ID for the iOS app"
AGENT=$(openclaw agents list 2>/dev/null | grep -oE '^- [a-zA-Z0-9_-]+ \(default\)' | awk '{print $2}')
if [ -n "$AGENT" ]; then
  ok "default agent is '$AGENT' — set AGENT ID = $AGENT in the app (chat history uses agent:$AGENT:main)"
  probe "POST /tools/invoke history agent:$AGENT:main" POST /tools/invoke "{\"tool\":\"sessions_history\",\"args\":{\"sessionKey\":\"agent:$AGENT:main\",\"limit\":1}}" '"ok":true'
else
  echo "  (could not detect default agent; run: openclaw agents list)"
fi

echo
if [ $FAIL = 0 ]; then
  echo "All good. In the iOS app use:  Gateway URL = $HOST   Agent ID = ${AGENT:-main}"
else
  echo "Some checks failed — see ✘ lines above."; exit 1
fi
