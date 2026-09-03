# openclaw-stats-server

Standalone extraction of the lightweight stats/admin server used alongside OpenClaw.

## Includes
- stats HTTP server on port 8765
- system, outreach, blog, and token stats scripts
- safe exec allowlist backend
- optional GoWA WhatsApp webhook handler
- iOS deployment helper

## Security model
- Protects endpoints with the OpenClaw gateway bearer token (`OPENCLAW_GATEWAY_TOKEN`)
- Intended to run behind nginx on a custom domain alongside OpenClaw
- Gateway should remain loopback-only; stats server is typically proxied under `/stats/*` and `/tools/*`

## Install (recommended)
From the repo root, on the machine running the gateway:
```bash
bash install.sh        # or: curl -fsSL https://raw.githubusercontent.com/FreQRiDeR/OpenClaw-ios/main/install.sh | bash
```
Installs to `~/.openclaw/openclaw-stats-server`, starts the server, configures Tailscale and verifies
every endpoint. Everything below is what the installer does, for when you want to do it by hand.

## Start
```bash
# Token is read from ~/.openclaw/openclaw.json automatically (do NOT use
# `openclaw config get gateway.auth.token` — it returns __OPENCLAW_REDACTED__).
bash scripts/dashboard/ensure_stats_server.sh          # start if not running
bash scripts/dashboard/ensure_stats_server.sh --force  # restart
```
The server binds to `127.0.0.1:8765` by default (set `STATS_SERVER_BIND=0.0.0.0` for LAN).
The script waits for `/stats/health` to answer 200 with the token it was given, so a
wrong token or port clash fails loudly instead of silently.

## Exposing it with Tailscale (one command)

The iOS app uses **one base URL** for three backends, so the proxy must split by path:

| Path | Backend |
|------|---------|
| `/` (`/tools/invoke`, `/v1/chat/completions`) | gateway `127.0.0.1:18789` |
| `/stats/*` | stats server `127.0.0.1:8765` |
| `/wa/*` (optional WhatsApp webhook) | stats server `127.0.0.1:8765` |

```bash
bash scripts/setup_tailscale.sh          # configure serve paths + start server + verify every endpoint
bash scripts/setup_tailscale.sh --verify # read-only health check
```
Equivalent manual commands:
```bash
tailscale serve --bg --set-path /      http://127.0.0.1:18789
tailscale serve --bg --set-path /stats http://127.0.0.1:8765/stats
tailscale serve --bg --set-path /wa    http://127.0.0.1:8765/wa
```

### Symptoms of a missing `/stats` route
If only `/` is mapped, every `/stats/*` request lands on the gateway:
- System Health: *"Data couldn't be read because it isn't in the correct format"* (the gateway returns its HTML web UI with HTTP 200)
- Memory & Skills / Tools / Tokens: *"Gateway HTTP 404 Response: Not Found"*
- Chat and Automations still work (they use the gateway directly)

The app now detects both cases and shows "Stats server not reachable … run setup_tailscale.sh".

### Agent ID
Chat history uses the session key `agent:<id>:main`. The ID in the app must match
`openclaw agents list` (→ `main (default)` on a stock install). A wrong ID returns
*"Agent-to-agent history is disabled"* and the chat shows no history. `setup_tailscale.sh`
prints the correct value.

## Files
- `scripts/dashboard/stats_server.py` — HTTP server
- `scripts/dashboard/*.py` — stat generators
- `scripts/wa_webhook_handler.py` — optional WhatsApp webhook handler
- `scripts/setup_tailscale.sh` — Tailscale routing + end-to-end verifier (`--verify` for read-only)
- `ios/deploy_stats.py` — legacy helper from the old `skill-ios-setup` skill; superseded by `../install.sh`

## Notes
This repo was extracted from a live OpenClaw workspace. It has been cleaned to remove hardcoded secrets and made more portable, but some exec commands still assume a nearby OpenClaw install and workspace layout.
