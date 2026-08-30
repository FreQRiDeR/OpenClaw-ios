#!/usr/bin/env python3
"""
Lightweight stats HTTP server for OpenClaw dashboard.
Runs on port 8765. Returns JSON for system, outreach, blog stats.
Secured with bearer token (same as gateway token).
"""
import http.server
import json
import os
import subprocess
import threading
import time

PORT = int(os.environ.get('STATS_SERVER_PORT', '8765'))
TOKEN = os.environ.get('OPENCLAW_GATEWAY_TOKEN', '')
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Workspace root — auto-detected from openclaw config, falls back to ~/.openclaw/workspace
def resolve_workspace():
    try:
        proc = subprocess.run(
            'openclaw config get agents.defaults.workspace 2>/dev/null',
            shell=True, capture_output=True, text=True, timeout=10
        )
        out = proc.stdout.strip().strip('"')
        if out and out not in ('null', '') and os.path.isdir(out):
            return out
    except Exception:
        pass
    # Fallback: parse config file
    config_path = os.path.expanduser('~/.openclaw/openclaw.json')
    if os.path.exists(config_path):
        try:
            import re
            with open(config_path) as f:
                content = f.read()
            m = re.search(r'"workspace"\s*:\s*"([^"]+)"', content)
            if m and os.path.isdir(m.group(1)):
                return m.group(1)
        except Exception:
            pass
    return os.path.expanduser('~/.openclaw/workspace')

WORKSPACE = resolve_workspace()
SKILLS_BASE = os.path.join(WORKSPACE, 'skills')
MEMORY_BASE = os.path.join(WORKSPACE, 'memory')

SCRIPTS = {
    # {base} is replaced at runtime with BASE_DIR,
    '/stats/system':   'python3 {base}/system_stats.py',
    '/stats/outreach': 'python3 {base}/outreach_stats.py',
    '/stats/blog':     'python3 {base}/blog_stats.py',
    '/stats/tokens':   None,  # handled separately — needs query param
}

# Simple in-memory cache: {cache_key: (timestamp, result)}
_cache = {}
_cache_ttl = {
    '/stats/system':   10,    # 10s
    '/stats/outreach': 300,   # 5min
    '/stats/blog':     300,   # 5min
    '/stats/tokens':   60,    # 1min
}
_lock = threading.Lock()


for k,v in list(SCRIPTS.items()):
    if isinstance(v, str):
        SCRIPTS[k] = v.format(base=BASE_DIR)

def run_script(cache_key, cmd):
    with _lock:
        now = time.time()
        base_path = cache_key.split('?')[0]
        ttl = _cache_ttl.get(base_path, 60)
        if cache_key in _cache:
            ts, result = _cache[cache_key]
            if now - ts < ttl:
                return result, True  # (data, from_cache)

    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        data = result.stdout.strip()
        json.loads(data)  # validate
        with _lock:
            _cache[cache_key] = (time.time(), data)
        return data, False
    except Exception as e:
        return json.dumps({'error': str(e), 'timestamp': int(time.time())}), False


EXEC_ALLOWLIST = {
    'doctor':          'openclaw doctor --non-interactive',
    'status':          'openclaw status --deep',
    'logs':            'openclaw logs --limit 50',
    'security-audit':  'openclaw security audit',
    'backup':          'openclaw backup create',
    'channels-status': 'openclaw channels status --probe',
    'config-validate': 'openclaw config validate',
    'memory-reindex':  'openclaw memory index --force',
    'session-cleanup': 'openclaw sessions cleanup --enforce',
    'plugin-update':   'openclaw plugins update --all',
    'restart-stats':   'bash {base}/ensure_stats_server.sh --force',
    'models-status':   'openclaw models status --json',
    'agents-list':     'openclaw agents list --json',
    'channels-list':   'openclaw channels list --json',
    'mcp-list':        'openclaw mcp list --json 2>/dev/null || echo "{}"',
}


def list_memory_files():
    """List workspace root files + memory/ subdirectory files.
    Format: root files first, then '---' separator, then memory/ paths.
    """
    root_files = []
    memory_files = []

    try:
        for entry in sorted(os.listdir(WORKSPACE)):
            full = os.path.join(WORKSPACE, entry)
            if os.path.isfile(full) and entry.endswith('.md'):
                root_files.append(entry)
    except OSError:
        pass

    try:
        for entry in sorted(os.listdir(MEMORY_BASE)):
            full = os.path.join(MEMORY_BASE, entry)
            if os.path.isfile(full) and entry.endswith('.md'):
                memory_files.append(f'memory/{entry}')
    except OSError:
        pass

    return '\n'.join(root_files + ['---'] + memory_files)


def list_skills():
    """List skill folder names (directories containing SKILL.md)."""
    skills = []
    try:
        for entry in sorted(os.listdir(SKILLS_BASE)):
            full = os.path.join(SKILLS_BASE, entry)
            if os.path.isdir(full) and os.path.isfile(os.path.join(full, 'SKILL.md')):
                skills.append(entry)
    except OSError:
        pass
    return '\n'.join(skills)


def read_workspace_file(rel_path):
    """Read a file from the workspace root (blocked path traversal)."""
    import re as _re
    if not rel_path or not _re.match(r'^[\w\-\.\/]+$', rel_path):
        return None, 'Invalid path'
    base = os.path.realpath(WORKSPACE)
    full = os.path.realpath(os.path.join(base, rel_path))
    if not full.startswith(base + '/'):
        return None, 'Path traversal not allowed'
    if not os.path.isfile(full):
        return None, f'File not found: {rel_path}'
    try:
        with open(full, 'r', encoding='utf-8', errors='replace') as fh:
            return fh.read(), None
    except OSError as e:
        return None, str(e)


class StatsHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # suppress default access log

    def send_json(self, code, data):
        body = data.encode('utf-8') if isinstance(data, str) else json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Authorization, Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()

    def do_POST(self):
        path = self.path.split('?')[0]
        # Tailscale serve / nginx may strip the /stats mount prefix
        if path == '/exec':
            path = '/stats/exec'

        # WhatsApp webhook — separate auth (GoWA secret header, no bearer token)
        if path == '/wa/webhook':
            # GoWA uses chunked transfer encoding — must read until connection closes
            te = self.headers.get('Transfer-Encoding', '')
            if 'chunked' in te.lower():
                body = b''
                while True:
                    size_line = self.rfile.readline().strip()
                    if not size_line:
                        break
                    try:
                        chunk_size = int(size_line, 16)
                    except ValueError:
                        break
                    if chunk_size == 0:
                        break
                    body += self.rfile.read(chunk_size)
                    self.rfile.read(2)  # CRLF after chunk
            else:
                length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(length) if length else b'{}'
            secret = self.headers.get('X-Hub-Signature-256', '')
            try:
                import sys as _sys
                _sys.path.insert(0, os.path.join(BASE_DIR, '..'))
                import importlib
                import wa_webhook_handler
                importlib.reload(wa_webhook_handler)
                result, status = wa_webhook_handler.handle_webhook(body, secret)
                self.send_json(status, result)
            except Exception as e:
                self.send_json(500, {'error': str(e)})
            return

        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer ') or auth[7:] != TOKEN:
            self.send_json(401, {'error': 'Unauthorized'})
            return

        if path == '/stats/exec':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length) if length else b'{}'
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                self.send_json(400, {'error': 'Invalid JSON'})
                return

            command_key = payload.get('command', '').strip()
            args = payload.get('args', '')

            # --- memory-list: workspace root .md files + memory/ subdirectory ---
            if command_key == 'memory-list':
                stdout = list_memory_files()
                self.send_json(200, {
                    'command': 'memory-list',
                    'exit_code': 0,
                    'stdout': stdout,
                    'stderr': '',
                    'duration_ms': 0,
                })
                return

            # --- skills-list: skill folder names ---
            if command_key == 'skills-list':
                stdout = list_skills()
                self.send_json(200, {
                    'command': 'skills-list',
                    'exit_code': 0,
                    'stdout': stdout,
                    'stderr': '',
                    'duration_ms': 0,
                })
                return

            # --- file-read: read any workspace file (root files, skills, etc.) ---
            if command_key == 'file-read':
                content, err = read_workspace_file((args or '').strip())
                if err:
                    self.send_json(404, {'error': err})
                    return
                # Return JSON so the app can parse path + text
                self.send_json(200, {
                    'command': 'file-read',
                    'exit_code': 0,
                    'stdout': json.dumps({'text': content, 'path': (args or '').strip()}),
                    'stderr': '',
                    'duration_ms': 0,
                })
                return

            # Parameterised commands — validated separately, never shell-interpolated unsafely
            if command_key == 'skill-read':
                import re as _re, os as _os
                raw_args = (args or '').strip()
                # Split into exactly two parts: skill-name and relative file path
                parts = raw_args.split(' ', 1)
                if len(parts) != 2 or not parts[0] or not parts[1]:
                    self.send_json(400, {'error': 'Usage: skill-read <skill-name> <relative-path>'})
                    return
                skill_name, rel_path = parts
                # Validate skill name
                if not _re.match(r'^[\w\-\.]+$', skill_name):
                    self.send_json(400, {'error': 'Invalid skill name'})
                    return
                # Build and resolve full path — blocks traversal
                base = _os.path.realpath(SKILLS_BASE)
                full_path = _os.path.realpath(_os.path.join(base, skill_name, rel_path))
                if not full_path.startswith(base + '/'):
                    self.send_json(403, {'error': 'Path traversal not allowed'})
                    return
                if not _os.path.isfile(full_path):
                    self.send_json(404, {'error': f'File not found: {skill_name}/{rel_path}'})
                    return
                try:
                    with open(full_path, 'r', encoding='utf-8', errors='replace') as fh:
                        content = fh.read()
                except OSError as e:
                    self.send_json(500, {'error': str(e)})
                    return
                self.send_json(200, {
                    'command': 'skill-read',
                    'skill': skill_name,
                    'path': rel_path,
                    'exit_code': 0,
                    'stdout': content,
                    'stderr': '',
                    'duration_ms': 0,
                })
                return

            if command_key == 'skill-files':
                skill_name = (args or '').strip()
                # Validate: alphanumeric, hyphens, underscores, dots only — no path traversal
                import re as _re
                if not skill_name or not _re.match(r'^[\w\-\.]+$', skill_name):
                    self.send_json(400, {'error': 'Invalid skill name'})
                    return
                import os as _os
                skill_dir = _os.path.join(SKILLS_BASE, skill_name)
                # Resolve to catch any symlink traversal
                skill_dir = _os.path.realpath(skill_dir)
                if not skill_dir.startswith(_os.path.realpath(SKILLS_BASE) + '/'):
                    self.send_json(403, {'error': 'Path traversal not allowed'})
                    return
                if not _os.path.isdir(skill_dir):
                    self.send_json(404, {'error': f'Skill not found: {skill_name!r}'})
                    return
                files = []
                for root, dirs, fnames in _os.walk(skill_dir):
                    # Skip hidden dirs and __pycache__
                    dirs[:] = [d for d in sorted(dirs) if not d.startswith('.') and d != '__pycache__']
                    for fname in sorted(fnames):
                        if fname.startswith('.'):
                            continue
                        full = _os.path.join(root, fname)
                        rel = _os.path.relpath(full, skill_dir)
                        files.append(rel)
                self.send_json(200, {
                    'command': 'skill-files',
                    'skill': skill_name,
                    'exit_code': 0,
                    'stdout': '\n'.join(files),
                    'stderr': '',
                    'duration_ms': 0,
                })
                return

            if command_key == 'tools-list':
                # Return native built-in tools + MCP tools, filtered by config allow/deny
                import re as _re, os as _os
                BUILTIN_TOOLS = [
                    {"name": "exec", "group": "runtime", "description": "Run shell commands"},
                    {"name": "process", "group": "runtime", "description": "Manage background processes"},
                    {"name": "read", "group": "fs", "description": "Read file contents"},
                    {"name": "write", "group": "fs", "description": "Write file contents"},
                    {"name": "edit", "group": "fs", "description": "Edit files with precise replacements"},
                    {"name": "web_search", "group": "web", "description": "Search the web"},
                    {"name": "web_fetch", "group": "web", "description": "Fetch and extract content from a URL"},
                    {"name": "browser", "group": "ui", "description": "Control a Chromium browser"},
                    {"name": "canvas", "group": "ui", "description": "Drive node Canvas"},
                    {"name": "message", "group": "messaging", "description": "Send messages across channels"},
                    {"name": "cron", "group": "automation", "description": "Manage scheduled jobs"},
                    {"name": "gateway", "group": "automation", "description": "Restart and configure gateway"},
                    {"name": "nodes", "group": "nodes", "description": "Discover and control paired devices"},
                    {"name": "image", "group": "media", "description": "Analyze images with vision model"},
                    {"name": "tts", "group": "media", "description": "Convert text to speech"},
                    {"name": "pdf", "group": "media", "description": "Analyze PDF documents"},
                    {"name": "sessions_list", "group": "sessions", "description": "List sessions"},
                    {"name": "sessions_history", "group": "sessions", "description": "Fetch session history"},
                    {"name": "sessions_send", "group": "sessions", "description": "Send message to session"},
                    {"name": "sessions_spawn", "group": "sessions", "description": "Spawn sub-agent"},
                    {"name": "sessions_yield", "group": "sessions", "description": "End current turn"},
                    {"name": "session_status", "group": "sessions", "description": "Show session status"},
                    {"name": "subagents", "group": "sessions", "description": "List/steer/kill sub-agents"},
                    {"name": "agents_list", "group": "sessions", "description": "List available agent IDs"},
                    {"name": "memory_search", "group": "memory", "description": "Semantic search memory files"},
                    {"name": "memory_get", "group": "memory", "description": "Read snippet from memory file"},
                    {"name": "search_engine", "group": "web", "description": "Scrape Google/Bing/Yandex results"},
                    {"name": "search_engine_batch", "group": "web", "description": "Run multiple search queries"},
                    {"name": "scrape_as_markdown", "group": "web", "description": "Scrape a webpage to markdown"},
                    {"name": "scrape_batch", "group": "web", "description": "Scrape multiple webpages"},
                ]
                # Read MCP servers and tool config via openclaw CLI (avoids JSON5 parsing)
                try:
                    mcp_proc = subprocess.run(
                        'openclaw mcp list --json', shell=True,
                        capture_output=True, text=True, timeout=15
                    )
                    mcp_cfg = json.loads(mcp_proc.stdout) if mcp_proc.stdout.strip() else {}
                    mcp_servers = list(mcp_cfg.keys())
                except Exception:
                    mcp_servers = []
                try:
                    cv_proc = subprocess.run(
                        'openclaw config validate --json 2>/dev/null', shell=True,
                        capture_output=True, text=True, timeout=15
                    )
                    cv = json.loads(cv_proc.stdout) if cv_proc.stdout.strip() else {}
                    tools_cfg = cv.get('config', {}).get('tools', {})
                    profile = tools_cfg.get('profile', 'full')
                    allow = tools_cfg.get('allow', [])
                    deny = tools_cfg.get('deny', [])
                except Exception:
                    profile = 'full'
                    allow = []
                    deny = []

                result = {
                    'profile': profile,
                    'allow': allow,
                    'deny': deny,
                    'native': BUILTIN_TOOLS,
                    'mcp_servers': mcp_servers,
                }
                self.send_json(200, {
                    'command': 'tools-list',
                    'exit_code': 0,
                    'stdout': json.dumps(result),
                    'stderr': '',
                    'duration_ms': 0,
                })
                return

            if command_key == 'mcp-tools':
                # Query each configured MCP server for its tools via JSON-RPC tools/list
                # MCP servers are stdio-based (spawned by openclaw), so we read config
                # and return the static tool schema by spawning each server briefly.
                # Fallback: return server names + status if tool query fails.
                import os as _os
                t0_mcp = time.time()
                try:
                    mcp_proc = subprocess.run(
                        'openclaw mcp list --json', shell=True,
                        capture_output=True, text=True, timeout=15
                    )
                    mcp_servers = json.loads(mcp_proc.stdout) if mcp_proc.stdout.strip() else {}
                except Exception as e:
                    self.send_json(500, {'error': f'Failed to read MCP config: {e}'})
                    return

                results = {}
                for server_name, server_cfg in mcp_servers.items():
                    cmd_bin = server_cfg.get('command', '')
                    cmd_args = server_cfg.get('args', [])
                    env_overrides = server_cfg.get('env', {})
                    full_cmd = [cmd_bin] + cmd_args

                    # Build env with overrides
                    env = dict(_os.environ)
                    env.update(env_overrides)

                    # JSON-RPC initialize + tools/list over stdio
                    init_msg = json.dumps({
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": {},
                            "clientInfo": {"name": "stats-server", "version": "1.0"}
                        }
                    }) + '\n'
                    tools_msg = json.dumps({
                        "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}
                    }) + '\n'

                    try:
                        proc = subprocess.Popen(
                            full_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env, text=True
                        )
                        stdout, _ = proc.communicate(
                            input=init_msg + tools_msg,
                            timeout=20
                        )
                        # Parse JSON-RPC responses — may have multiple newline-delimited objects
                        tools = []
                        for line in stdout.strip().splitlines():
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                resp = json.loads(line)
                                if resp.get('id') == 2 and 'result' in resp:
                                    tools = resp['result'].get('tools', [])
                                    break
                            except json.JSONDecodeError:
                                continue
                        results[server_name] = {
                            'status': 'ok',
                            'tool_count': len(tools),
                            'tools': [{'name': t.get('name'), 'description': t.get('description', '')} for t in tools],
                        }
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        results[server_name] = {'status': 'timeout', 'tool_count': 0, 'tools': []}
                    except Exception as e:
                        results[server_name] = {'status': 'error', 'error': str(e), 'tool_count': 0, 'tools': []}

                duration_ms = int((time.time() - t0_mcp) * 1000)
                self.send_json(200, {
                    'command': 'mcp-tools',
                    'exit_code': 0,
                    'stdout': json.dumps({'servers': results}),
                    'stderr': '',
                    'duration_ms': duration_ms,
                })
                return

            if command_key not in EXEC_ALLOWLIST:
                self.send_json(403, {
                    'error': f'Command not allowed: {command_key!r}',
                    'allowed': list(EXEC_ALLOWLIST.keys()) + ['skill-files', 'skill-read', 'memory-list', 'skills-list', 'file-read', 'mcp-tools'],
                })
                return

            cmd = EXEC_ALLOWLIST[command_key].format(base=BASE_DIR)
            t0 = time.time()
            try:
                proc = subprocess.run(
                    cmd, shell=True, capture_output=True, text=True, timeout=60
                )
                duration_ms = int((time.time() - t0) * 1000)
                self.send_json(200, {
                    'command': command_key,
                    'exit_code': proc.returncode,
                    'stdout': proc.stdout,
                    'stderr': proc.stderr,
                    'duration_ms': duration_ms,
                })
            except subprocess.TimeoutExpired:
                self.send_json(200, {
                    'command': command_key,
                    'exit_code': -1,
                    'stdout': '',
                    'stderr': 'Command timed out after 60s',
                    'duration_ms': 60000,
                })
            except Exception as e:
                self.send_json(500, {'error': str(e)})
            return

        self.send_json(404, {'error': f'Unknown endpoint: {path}'})

    def do_GET(self):
        # Auth check
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer ') or auth[7:] != TOKEN:
            self.send_json(401, {'error': 'Unauthorized'})
            return

        full_path = self.path
        path = full_path.split('?')[0]
        # Tailscale serve / nginx may strip the /stats mount prefix
        if not path.startswith('/stats/') and path in ('/health', '/system', '/outreach', '/blog', '/tokens'):
            path = '/stats' + path

        if path == '/stats/health':
            self.send_json(200, {'ok': True, 'timestamp': int(time.time())})
            return

        if path not in SCRIPTS:
            self.send_json(404, {'error': f'Unknown endpoint: {path}'})
            return

        # Handle token stats separately — needs query param
        if path == '/stats/tokens':
            import urllib.parse
            qs = urllib.parse.parse_qs(full_path.split('?', 1)[1] if '?' in full_path else '')
            period = qs.get('period', ['today'])[0]
            if period not in ('today', 'yesterday', 'week'):
                period = 'today'
            cache_key = f'/stats/tokens?period={period}'
            cmd = f'python3 {BASE_DIR}/token_stats.py {period}'
            data, _ = run_script(cache_key, cmd)
            self.send_json(200, data)
            return

        cmd = SCRIPTS[path]
        data, _ = run_script(path, cmd)
        self.send_json(200, data)


if __name__ == '__main__':
    if not TOKEN:
        print('ERROR: OPENCLAW_GATEWAY_TOKEN not set')
        exit(1)
    server = http.server.ThreadingHTTPServer(('0.0.0.0', PORT), StatsHandler)
    print(f'Stats server running on port {PORT}')
    server.serve_forever()