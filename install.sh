#!/bin/bash
# OpenClaw iOS — server-side one-shot installer.
#
# Installs the stats server the iOS app depends on, starts it, wires up Tailscale
# and verifies every endpoint the app uses. Replaces the `skill-ios-setup` skill.
#
# Run on the machine that hosts your OpenClaw gateway:
#
#   From a clone:     bash install.sh
#   Without a clone:  curl -fsSL https://raw.githubusercontent.com/FreQRiDeR/OpenClaw-ios/main/install.sh | bash
#
# Options:
#   --no-tailscale   install + start the server only (you're using nginx / LAN instead)
#   --dest DIR       install location (default: ~/.openclaw/openclaw-stats-server)
#   --force          overwrite an existing install without asking
#
# Env overrides: OPENCLAW_GATEWAY_PORT (18789), STATS_SERVER_PORT (8765)
set -u

# Branch to download from when no local copy is found (override: OPENCLAW_IOS_BRANCH=main)
REPO_BRANCH="${OPENCLAW_IOS_BRANCH:-Windows_Server}"
REPO_RAW="https://raw.githubusercontent.com/FreQRiDeR/OpenClaw-ios/$REPO_BRANCH"
DEST="${HOME}/.openclaw/openclaw-stats-server"
DO_TAILSCALE=1
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-tailscale) DO_TAILSCALE=0 ;;
    --dest) shift; DEST="$1" ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# When piped through `curl | bash`, $0 is "bash" and there is no script dir.
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ---------------------------------------------------------------------------
step "1. Prerequisites"
command -v python3 >/dev/null 2>&1 && ok "python3 $(python3 --version 2>&1 | awk '{print $2}')" || die "python3 not found"
command -v curl    >/dev/null 2>&1 && ok "curl" || die "curl not found"
command -v unzip   >/dev/null 2>&1 && ok "unzip" || die "unzip not found"
if command -v openclaw >/dev/null 2>&1; then ok "openclaw CLI"; else die "openclaw CLI not found in PATH — install OpenClaw first"; fi
CONFIG="$HOME/.openclaw/openclaw.json"
[ -f "$CONFIG" ] && ok "config: $CONFIG" || die "no $CONFIG — run 'openclaw' once to create it"

TOKEN=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
[ -n "$TOKEN" ] && ok "gateway token found (${#TOKEN} chars)" || die "gateway.auth.token missing in $CONFIG"

if [ $DO_TAILSCALE = 1 ]; then
  if command -v tailscale >/dev/null 2>&1 || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    ok "tailscale CLI"
  else
    warn "tailscale CLI not found — will install + start the server, but skip proxy setup (use --no-tailscale to silence)"
    DO_TAILSCALE=0
  fi
fi

# ---------------------------------------------------------------------------
step "2. Gateway config the app needs"
# Warn-only: we never edit openclaw.json for you.
python3 - "$CONFIG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
ok   = lambda m: print(f"  \033[32m\u2714\033[0m {m}")
warn = lambda m: print(f"  \033[33m!\033[0m {m}")
if c.get("gateway",{}).get("http",{}).get("endpoints",{}).get("chatCompletions",{}).get("enabled") is True:
    ok("gateway.http.endpoints.chatCompletions.enabled = true")
else:
    warn('Chat will not work: set gateway.http.endpoints.chatCompletions = {"enabled": true}')
if c.get("tools",{}).get("sessions",{}).get("visibility") == "all":
    ok("tools.sessions.visibility = all")
else:
    warn('Sessions tab will be empty: set tools.sessions.visibility = "all"')
g = c.get("gateway", {})
trusted = g.get("trustedProxies", [])
if "127.0.0.1" in trusted:
    ok("gateway.trustedProxies narrowly trusts the IPv4 loopback proxy")
else:
    warn('External Tailscale proxy needs gateway.trustedProxies = ["127.0.0.1"] (otherwise HTTP 403 proxy attribution)')
auth = g.get("auth", {})
if auth.get("mode") == "token": ok("gateway.auth.mode = token")
else: warn("Keep bearer token auth enabled: gateway.auth.mode = token")
if auth.get("allowTailscale") is False: ok("gateway.auth.allowTailscale = false")
else: warn("External Serve should use the bearer token: gateway.auth.allowTailscale = false")
if g.get("tailscale", {}).get("mode") == "off": ok("gateway.tailscale.mode = off (external Serve is sole owner)")
else: warn("External Serve must be the sole owner: gateway.tailscale.mode = off")
need = ["exec","cron","gateway","sessions_list","sessions_history","memory_get"]
allow = c.get("tools",{}).get("allow")
profile = c.get("tools",{}).get("profile")
if allow is None and profile in (None, "full"):
    ok("tools.allow not set — full profile, all tools available")
else:
    missing = [t for t in need if t not in (allow or [])]
    if missing: warn(f"tools.allow is missing: {', '.join(missing)}  (Automations / Sessions / Memory cards need these)")
    else: ok("tools.allow includes everything the app uses")
PY

# ---------------------------------------------------------------------------
step "3. Locate stats server files"
# Priority: repo checkout next to script -> zip next to script (docs/ or loose) -> download.
# The install destination is never used as a source (it is deleted before copying).
SRC_DIR=""; SRC_ZIP=""; TMPDIR_DL=""
abs() { (cd "$1" 2>/dev/null && pwd -P); }
if [ -n "$SCRIPT_DIR" ]; then
  CAND="$SCRIPT_DIR/openclaw-stats-server"
  if [ -f "$CAND/scripts/dashboard/stats_server.py" ] && [ "$(abs "$CAND")" != "$(abs "$DEST")" ]; then
    SRC_DIR="$CAND"; ok "using repo checkout: $SRC_DIR"
  else
    for z in "$SCRIPT_DIR/docs/openclaw-stats-server.zip" "$SCRIPT_DIR/openclaw-stats-server.zip"; do
      if [ -f "$z" ]; then SRC_ZIP="$z"; ok "using local zip: $SRC_ZIP"; break; fi
    done
  fi
fi
if [ -z "$SRC_DIR" ] && [ -z "$SRC_ZIP" ]; then
  TMPDIR_DL=$(mktemp -d); SRC_ZIP="$TMPDIR_DL/openclaw-stats-server.zip"
  echo "  no local copy found — downloading $REPO_RAW/docs/openclaw-stats-server.zip …"
  curl -fsSL "$REPO_RAW/docs/openclaw-stats-server.zip" -o "$SRC_ZIP" || die "download failed"
  ok "downloaded $(du -h "$SRC_ZIP" | awk '{print $1}') from branch '$REPO_BRANCH'"
fi

# ---------------------------------------------------------------------------
step "4. Install to $DEST"
if [ -d "$DEST" ] && [ $FORCE = 0 ]; then
  if [ -t 0 ]; then
    read -r -p "  $DEST already exists. Overwrite? [y/N] " ans
    case "$ans" in y|Y) ;; *) echo "  aborted"; exit 1 ;; esac
  else
    warn "$DEST exists — overwriting (non-interactive; pass --force to silence)"
  fi
fi
# Stop a running instance so we don't replace files under it
if pgrep -f stats_server.py >/dev/null 2>&1; then
  pkill -f stats_server.py; sleep 1; ok "stopped running stats server"
fi
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
if [ -n "$SRC_DIR" ]; then
  cp -R "$SRC_DIR" "$DEST"
else
  EX=$(mktemp -d)
  unzip -q "$SRC_ZIP" -d "$EX" || die "unzip failed"
  # zip contains a top-level openclaw-stats-server/ folder (+ macOS __MACOSX junk)
  INNER=$(find "$EX" -name stats_server.py -path '*/scripts/dashboard/*' -not -path '*/__MACOSX/*' 2>/dev/null | head -1)
  [ -n "$INNER" ] || die "stats_server.py not found inside zip"
  mv "$(cd "$(dirname "$INNER")/../.." && pwd)" "$DEST"
  rm -rf "$EX"
fi
[ -n "$TMPDIR_DL" ] && rm -rf "$TMPDIR_DL"
find "$DEST" -name '.DS_Store' -delete 2>/dev/null
find "$DEST" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
chmod +x "$DEST"/scripts/*.sh "$DEST"/scripts/dashboard/*.sh 2>/dev/null
python3 -m py_compile "$DEST/scripts/dashboard/stats_server.py" || die "stats_server.py failed to compile"
rm -rf "$DEST/scripts/dashboard/__pycache__"
# Sanity: refuse a copy that predates the cross-platform server (old zip / wrong branch)
for req in scripts/setup_tailscale.sh scripts/dashboard/ensure_stats_server.sh scripts/setup_tailscale.ps1 scripts/configure_gateway_proxy.ps1; do
  [ -f "$DEST/$req" ] || { rm -rf "$DEST"; die "installed copy is missing $req — stale zip or wrong branch. Re-zip from the current branch (or set OPENCLAW_IOS_BRANCH)."; }
done
grep -q IS_WIN "$DEST/scripts/dashboard/system_stats.py" || { rm -rf "$DEST"; die "system_stats.py predates cross-platform support — stale zip."; }
ok "installed $(find "$DEST" -type f | wc -l | tr -d ' ') files (cross-platform build verified)"

# ---------------------------------------------------------------------------
step "5. Start stats server"
unset OPENCLAW_GATEWAY_TOKEN   # let ensure_stats_server.sh read the real token from the config file
if bash "$DEST/scripts/dashboard/ensure_stats_server.sh" --force; then
  :
else
  bad "stats server did not come up — last log lines:"; tail -10 /tmp/stats_server.log 2>/dev/null; exit 1
fi

# ---------------------------------------------------------------------------
if [ $DO_TAILSCALE = 1 ]; then
  step "6. Tailscale routing + end-to-end verification"
  bash "$DEST/scripts/setup_tailscale.sh" || exit 1
else
  step "6. Tailscale skipped"
  echo "  Expose these two ports behind ONE hostname (nginx example):"
  echo "    location /stats/ { proxy_pass http://127.0.0.1:${STATS_SERVER_PORT:-8765}; }"
  echo "    location /       { proxy_pass http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}; }"
  echo "  Then: bash $DEST/scripts/setup_tailscale.sh --verify   (works for any proxy that maps /stats)"
fi

# ---------------------------------------------------------------------------
step "Done"
cat <<EOF
  Installed to: $DEST

  Day-to-day:
    start/restart   bash $DEST/scripts/dashboard/ensure_stats_server.sh --force
    stop            pkill -f stats_server.py
    health check    bash $DEST/scripts/setup_tailscale.sh --verify
    logs            tail -f /tmp/stats_server.log

  The server does not auto-start on reboot (by design). Re-run the start command after a restart.
EOF
