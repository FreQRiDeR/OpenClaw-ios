#!/usr/bin/env python3
"""Hit the live stats server with the token from the running server's env."""
import os, re, subprocess, urllib.request

out = subprocess.run(['ps', 'eww', '-p', '98637'], capture_output=True, text=True).stdout or ''
m = re.search(r'OPENCLAW_GATEWAY_TOKEN=(\S+)', out)
tok = m.group(1) if m else ''
print(f'token_len={len(tok)}')

for ep in ['/stats/health', '/stats/system', '/stats/tokens?period=today', '/stats/outreach', '/stats/blog']:
    req = urllib.request.Request(f'http://localhost:8765{ep}', headers={'Authorization': f'Bearer {tok}'})
    try:
        r = urllib.request.urlopen(req, timeout=40)
        body = r.read().decode('utf-8', 'replace')
        print(f'--- GET {ep} -> HTTP {r.status} ---')
        print(body[:900])
    except urllib.error.HTTPError as e:
        print(f'--- GET {ep} -> HTTP {e.code} ---')
        print(e.read().decode('utf-8', 'replace')[:900])
    except Exception as e:
        print(f'--- GET {ep} -> ERROR {e} ---')
