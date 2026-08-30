#!/usr/bin/env python3
"""
Dashboard: blog pipeline stats card
Returns JSON: published, queued, writing, generating_images, publishing, last_published_title, last_published_slug
"""
import json, os, time, urllib.request

try:
    NOTION_API_KEY = open(os.path.expanduser('~/.config/notion/api_key')).read().strip()
except Exception:
    NOTION_API_KEY = ''
NOTION_VERSION = '2022-06-28'
BLOG_DB = '32b9e49d-5499-8128-a42b-f1359a8c8485'

def query_blog(filter_body=None):
    total = []
    has_more = True
    cursor = None
    while has_more:
        url = f'https://api.notion.com/v1/databases/{BLOG_DB}/query'
        body = {'page_size': 100}
        if filter_body:
            body['filter'] = filter_body
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
        total.extend(data.get('results', []))
        has_more = data.get('has_more', False)
        cursor = data.get('next_cursor')
    return total

try:
    def count_status(s):
        pages = query_blog({'property': 'Status', 'select': {'equals': s}})
        return len(pages)

    published_pages = query_blog({'property': 'Status', 'select': {'equals': 'Published'}})
    # Sort by last_edited_time descending to find most recent
    published_pages.sort(key=lambda p: p.get('last_edited_time', ''), reverse=True)

    last_title = None
    last_slug = None
    if published_pages:
        page = published_pages[0]
        title_parts = page.get('properties', {}).get('Name', {}).get('title', [])
        last_title = ''.join(t.get('plain_text', '') for t in title_parts) if title_parts else None
        slug_parts = page.get('properties', {}).get('Slug', {}).get('rich_text', [])
        last_slug = ''.join(t.get('plain_text', '') for t in slug_parts) if slug_parts else None

    result = {
        'timestamp': int(time.time()),
        'published': len(published_pages),
        'queued': count_status('Queued'),
        'researching': count_status('Researching'),
        'writing': count_status('Writing'),
        'generating_images': count_status('Generating Images'),
        'publishing': count_status('Publishing'),
        'last_published_title': last_title,
        'last_published_slug': last_slug,
        'last_published_url': f'https://appwebdev.co.uk/blog/{last_slug}' if last_slug else None,
    }

except Exception as e:
    result = {'error': str(e), 'timestamp': int(time.time())}

print(json.dumps(result))
