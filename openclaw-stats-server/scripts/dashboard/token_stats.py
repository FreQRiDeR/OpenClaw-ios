#!/usr/bin/env python3
"""
Token usage stats from OpenClaw session JSONL transcripts.
Returns detailed breakdown: per-model, thinking vs tool vs text, cache, cost.

Usage: python3 token_stats.py [today|yesterday|week]
"""
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta

# Default sessions dir: ~/.openclaw/agents/main/sessions (matches active agent)
# Override with OPENCLAW_SESSIONS_DIR env var, or auto-detect from config.
def resolve_sessions_dir():
    env_dir = os.environ.get('OPENCLAW_SESSIONS_DIR', '')
    if env_dir and os.path.isdir(env_dir):
        return env_dir

    # Auto-detect agent id from openclaw config (agents.list[0].id)
    config_path = os.path.expanduser('~/.openclaw/openclaw.json')
    try:
        import re
        with open(config_path) as f:
            content = f.read()
        # Match the first agent id in agents.list or agents.defaults
        m = re.search(r'"id"\s*:\s*"([^"]+)"', content)
        agent_id = m.group(1) if m else 'main'
        for candidate in [
            os.path.expanduser(f'~/.openclaw/agents/{agent_id}/sessions'),
            os.path.expanduser('~/.openclaw/agents/main/sessions'),
        ]:
            if os.path.isdir(candidate):
                return candidate
    except Exception:
        pass

    return os.path.expanduser('~/.openclaw/agents/main/sessions')


def period_bounds(period: str):
    now = datetime.now(timezone.utc)
    today_midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == 'today':
        return int(today_midnight.timestamp() * 1000), int(now.timestamp() * 1000)
    elif period == 'yesterday':
        start = today_midnight - timedelta(days=1)
        return int(start.timestamp() * 1000), int(today_midnight.timestamp() * 1000)
    elif period == 'week':
        start = today_midnight - timedelta(days=7)
        return int(start.timestamp() * 1000), int(now.timestamp() * 1000)
    else:
        return int(today_midnight.timestamp() * 1000), int(now.timestamp() * 1000)


def parse_ts(ts_str: str) -> int:
    try:
        dt = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
        return int(dt.timestamp() * 1000)
    except Exception:
        return 0


def process_files(start_ms: int, end_ms: int, sessions_dir: str):
    # Aggregation buckets
    totals = {
        'input_tokens': 0,
        'output_tokens': 0,
        'cache_read_tokens': 0,
        'cache_write_tokens': 0,
        'total_tokens': 0,
        'request_count': 0,
        'thinking_requests': 0,   # requests that included a thinking block
        'tool_requests': 0,        # requests that called at least one tool
        'cost_usd': 0.0,
    }

    # Per-model breakdown: model_id -> same fields
    by_model = defaultdict(lambda: {
        'input_tokens': 0,
        'output_tokens': 0,
        'cache_read_tokens': 0,
        'cache_write_tokens': 0,
        'total_tokens': 0,
        'request_count': 0,
        'thinking_requests': 0,
        'tool_requests': 0,
        'cost_usd': 0.0,
        'provider': '',
    })

    if not os.path.isdir(sessions_dir):
        return totals, {}

    for fname in os.listdir(sessions_dir):
        if not fname.endswith('.jsonl'):
            continue
        fpath = os.path.join(sessions_dir, fname)
        try:
            mtime_ms = int(os.path.getmtime(fpath) * 1000)
            if mtime_ms < start_ms:
                continue
        except OSError:
            continue

        try:
            with open(fpath, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    if event.get('type') != 'message':
                        continue

                    msg = event.get('message', {})
                    if msg.get('role') != 'assistant':
                        continue

                    ts = parse_ts(event.get('timestamp', ''))
                    if ts < start_ms or ts > end_ms:
                        continue

                    usage = msg.get('usage', {})
                    if not usage:
                        continue

                    inp        = usage.get('input', 0) or 0
                    out        = usage.get('output', 0) or 0
                    cache_read = usage.get('cacheRead', 0) or 0
                    cache_write= usage.get('cacheWrite', 0) or 0
                    tot        = usage.get('totalTokens', 0) or 0
                    if tot == 0:
                        tot = inp + out + cache_read

                    cost_obj   = usage.get('cost', {}) or {}
                    cost       = cost_obj.get('total', 0.0) or 0.0

                    content    = msg.get('content', [])
                    ctypes     = [c.get('type') for c in content]
                    has_think  = 'thinking' in ctypes
                    has_tool   = 'toolCall' in ctypes

                    model_key  = msg.get('model') or 'unknown'
                    provider   = msg.get('provider') or ''

                    # Global totals
                    totals['input_tokens']       += inp
                    totals['output_tokens']       += out
                    totals['cache_read_tokens']   += cache_read
                    totals['cache_write_tokens']  += cache_write
                    totals['total_tokens']        += tot
                    totals['request_count']       += 1
                    totals['cost_usd']            += cost
                    if has_think: totals['thinking_requests'] += 1
                    if has_tool:  totals['tool_requests']     += 1

                    # Per-model
                    bm = by_model[model_key]
                    bm['input_tokens']       += inp
                    bm['output_tokens']       += out
                    bm['cache_read_tokens']   += cache_read
                    bm['cache_write_tokens']  += cache_write
                    bm['total_tokens']        += tot
                    bm['request_count']       += 1
                    bm['cost_usd']            += cost
                    bm['provider']             = provider
                    if has_think: bm['thinking_requests'] += 1
                    if has_tool:  bm['tool_requests']     += 1

        except (OSError, IOError):
            continue

    return totals, dict(by_model)


def main():
    period = sys.argv[1] if len(sys.argv) > 1 else 'today'
    if len(sys.argv) > 2:
        os.environ['OPENCLAW_SESSIONS_DIR'] = sys.argv[2]
    start_ms, end_ms = period_bounds(period)
    sessions_dir = resolve_sessions_dir()
    totals, by_model = process_files(start_ms, end_ms, sessions_dir)

    # Sort models by total_tokens desc
    models_list = sorted(
        [{'model': k, **v} for k, v in by_model.items()],
        key=lambda x: x['total_tokens'],
        reverse=True
    )

    # Round cost
    totals['cost_usd'] = round(totals['cost_usd'], 4)
    for m in models_list:
        m['cost_usd'] = round(m['cost_usd'], 4)

    print(json.dumps({
        'period': period,
        'sessions_dir': sessions_dir,
        'totals': totals,
        'by_model': models_list,
    }))


if __name__ == '__main__':
    import sys
    main()