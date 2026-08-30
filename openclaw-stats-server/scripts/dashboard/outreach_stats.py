#!/usr/bin/env python3
"""
Dashboard: outreach stats card
Returns JSON: total_leads, new_leads, email_sent, wa_sent, replied, converted
"""
import json, sys, os, time

try:
    NOTION_API_KEY = open(os.path.expanduser('~/.config/notion/api_key')).read().strip()
except Exception:
    NOTION_API_KEY = ''
NOTION_VERSION = '2022-06-28'
LEADS_DB = os.environ.get('NOTION_LEADS_DB', '')

try:
    import urllib.request

    def notion_query(database_id, filter_body=None, page_size=1):
        url = f'https://api.notion.com/v1/databases/{database_id}/query'
        body = {'page_size': page_size}
        if filter_body:
            body['filter'] = filter_body
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode(),
            headers={
                'Authorization': f'Bearer {NOTION_API_KEY}',
                'Notion-Version': NOTION_VERSION,
                'Content-Type': 'application/json',
            },
            method='POST'
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())

    def count_all():
        """Paginate and count total leads"""
        total = 0
        has_more = True
        cursor = None
        while has_more:
            url = f'https://api.notion.com/v1/databases/{LEADS_DB}/query'
            body = {'page_size': 100}
            if cursor:
                body['start_cursor'] = cursor
            req = urllib.request.Request(
                url, data=json.dumps(body).encode(),
                headers={
                    'Authorization': f'Bearer {NOTION_API_KEY}',
                    'Notion-Version': NOTION_VERSION,
                    'Content-Type': 'application/json',
                },
                method='POST'
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
            results = data.get('results', [])
            total += len(results)
            has_more = data.get('has_more', False)
            cursor = data.get('next_cursor')
        return total

    def count_with_pipeline_tag(tag):
        """Count leads that have a specific tag in the Pipeline multi-select"""
        total = 0
        has_more = True
        cursor = None
        while has_more:
            url = f'https://api.notion.com/v1/databases/{LEADS_DB}/query'
            body = {
                'page_size': 100,
                'filter': {
                    'property': 'Pipeline',
                    'multi_select': {'contains': tag}
                }
            }
            if cursor:
                body['start_cursor'] = cursor
            req = urllib.request.Request(
                url, data=json.dumps(body).encode(),
                headers={
                    'Authorization': f'Bearer {NOTION_API_KEY}',
                    'Notion-Version': NOTION_VERSION,
                    'Content-Type': 'application/json',
                },
                method='POST'
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
            total += len(data.get('results', []))
            has_more = data.get('has_more', False)
            cursor = data.get('next_cursor')
        return total

    def count_with_status(status):
        total = 0
        has_more = True
        cursor = None
        while has_more:
            url = f'https://api.notion.com/v1/databases/{LEADS_DB}/query'
            body = {
                'page_size': 100,
                'filter': {'property': 'Status', 'select': {'equals': status}}
            }
            if cursor:
                body['start_cursor'] = cursor
            req = urllib.request.Request(
                url, data=json.dumps(body).encode(),
                headers={
                    'Authorization': f'Bearer {NOTION_API_KEY}',
                    'Notion-Version': NOTION_VERSION,
                    'Content-Type': 'application/json',
                },
                method='POST'
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
            total += len(data.get('results', []))
            has_more = data.get('has_more', False)
            cursor = data.get('next_cursor')
        return total

    total = count_all()
    email_sent = count_with_pipeline_tag('Email Sent')
    wa_sent = count_with_pipeline_tag('WA Sent')
    replied = count_with_status('Replied')
    converted = count_with_status('Converted')
    new_leads = count_with_status('New')

    result = {
        'timestamp': int(time.time()),
        'total_leads': total,
        'new_leads': new_leads,
        'email_sent': email_sent,
        'wa_sent': wa_sent,
        'replied': replied,
        'converted': converted,
        'reply_rate_pct': round(replied / email_sent * 100, 1) if email_sent > 0 else 0,
    }

except Exception as e:
    result = {'error': str(e), 'timestamp': int(time.time())}

print(json.dumps(result))
