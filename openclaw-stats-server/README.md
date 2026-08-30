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

## Start
```bash
export OPENCLAW_GATEWAY_TOKEN=...
bash scripts/dashboard/ensure_stats_server.sh
```

## Files
- `scripts/dashboard/stats_server.py` — HTTP server
- `scripts/dashboard/*.py` — stat generators
- `scripts/wa_webhook_handler.py` — optional WhatsApp webhook handler
- `ios/deploy_stats.py` — helper used by iOS setup flow

## Notes
This repo was extracted from a live OpenClaw workspace. It has been cleaned to remove hardcoded secrets and made more portable, but some exec commands still assume a nearby OpenClaw install and workspace layout.
