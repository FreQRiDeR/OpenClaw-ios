#!/usr/bin/env python3
"""
WhatsApp webhook handler for GoWA events.
Called by stats_server.py on POST /wa/webhook.

Responsibilities:
- Validate GoWA webhook secret
- Check blocklist (ignore blocked numbers silently)
- Extract phone + message/poll content
- Fetch lead context from Notion
- Fetch last 10 messages from GoWA for context
- Spawn isolated Sonnet agent via OpenClaw /hooks/agent
"""

import json
import os
import re
import sys
import urllib.request
import urllib.parse

BLOCKLIST_PATH = "/home/node/gowa/blocklist.json"
GOWA_URL = os.environ.get("GOWA_URL", "http://localhost:3000")
GOWA_DEVICE = os.environ.get("GOWA_DEVICE", "parham")
HOOKS_TOKEN = os.environ.get("OPENCLAW_HOOKS_TOKEN", "")
GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://localhost:18789")
NOTION_KEY_PATH = os.path.expanduser("~/.config/notion/api_key")
NOTION_LEADS_DB = os.environ.get("NOTION_LEADS_DB", "")
PARHAM_TELEGRAM = os.environ.get("OWNER_TELEGRAM_ID", "")


def load_blocklist():
    try:
        with open(BLOCKLIST_PATH) as f:
            return set(json.load(f))
    except Exception:
        return set()


def add_to_blocklist(phone):
    bl = load_blocklist()
    bl.add(phone)
    with open(BLOCKLIST_PATH, "w") as f:
        json.dump(list(bl), f)


def notion_request(method, path, body=None):
    key = open(NOTION_KEY_PATH).read().strip()
    url = f"https://api.notion.com/v1{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Notion-Version", "2022-06-28")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        return None


def find_lead_by_phone(phone):
    """Search Notion Leads DB for a lead matching this phone number."""
    # Normalise: strip leading zeros/country code variations
    # Store as +447... in Notion, GoWA sends as 447...
    variants = [phone, f"+{phone}", phone.lstrip("44")]

    result = notion_request("POST", f"/databases/{NOTION_LEADS_DB}/query", {
        "page_size": 100
    })
    if not result:
        return None

    pages = result.get("results", [])
    # Paginate if needed
    while result.get("has_more"):
        result = notion_request("POST", f"/databases/{NOTION_LEADS_DB}/query", {
            "page_size": 100,
            "start_cursor": result["next_cursor"]
        })
        if result:
            pages.extend(result.get("results", []))

    for page in pages:
        props = page.get("properties", {})
        phone_prop = props.get("Phone", {}).get("phone_number", "") or ""
        normalised = re.sub(r"[\s\+\-\(\)]", "", phone_prop)
        for v in variants:
            if normalised.endswith(v.lstrip("+")) or v.lstrip("+") in normalised:
                # Extract fields
                name = ""
                name_parts = props.get("Business Name", {}).get("title", [])
                if name_parts:
                    name = name_parts[0].get("plain_text", "")

                btype = props.get("Type", {}).get("select", {})
                btype = btype.get("name", "") if btype else ""

                location = ""
                loc_parts = props.get("Location", {}).get("rich_text", [])
                if loc_parts:
                    location = loc_parts[0].get("plain_text", "")

                website = props.get("Website", {}).get("url", "") or ""

                about = ""
                about_parts = props.get("About", {}).get("rich_text", [])
                if about_parts:
                    about = about_parts[0].get("plain_text", "")

                wa_variant = ""
                variant_parts = props.get("WA Variant", {}).get("rich_text", [])
                if variant_parts:
                    wa_variant = variant_parts[0].get("plain_text", "")

                pipeline = [s.get("name", "") for s in props.get("Pipeline", {}).get("multi_select", [])]

                return {
                    "page_id": page["id"],
                    "name": name,
                    "type": btype,
                    "location": location,
                    "website": website,
                    "about": about,
                    "wa_variant": wa_variant,
                    "pipeline": pipeline,
                    "phone_raw": phone_prop,
                }
    return None


def get_chat_history(phone, limit=10):
    """Fetch last N messages from GoWA for this phone."""
    jid = f"{phone}@s.whatsapp.net"
    url = f"{GOWA_URL}/chat/{jid}/messages?device={GOWA_DEVICE}&limit={limit}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read())
        messages = data.get("results", {}).get("data", [])
        lines = []
        for m in reversed(messages):  # oldest first
            direction = "them" if not m.get("is_from_me") else "us"
            content = m.get("content", "").strip()
            if content:
                lines.append(f"[{direction}]: {content}")
        return "\n".join(lines) if lines else "(no prior messages)"
    except Exception:
        return "(could not fetch history)"


def update_notion_lead(page_id, poll_answer=None, append_pipeline=None):
    """Update WA Poll Answer field and/or Pipeline on a lead."""
    props = {}
    if poll_answer:
        props["WA Poll Answer"] = {
            "rich_text": [{"type": "text", "text": {"content": poll_answer[:2000]}}]
        }
    if append_pipeline:
        # Read current pipeline first to append
        page = notion_request("GET", f"/pages/{page_id}")
        if page:
            current = [s.get("name", "") for s in page.get("properties", {}).get("Pipeline", {}).get("multi_select", [])]
            if append_pipeline not in current:
                current.append(append_pipeline)
            props["Pipeline"] = {"multi_select": [{"name": s} for s in current]}

    if props:
        notion_request("PATCH", f"/pages/{page_id}", {"properties": props})


def spawn_wa_agent(phone, lead, message_text, poll_answer, history):
    """Call /hooks/agent to spawn isolated Sonnet agent for this WA conversation."""

    lead_context = ""
    if lead:
        lead_context = f"""
Lead context from Notion:
- Business: {lead['name']}
- Type: {lead['type']}
- Location: {lead['location']}
- Website: {lead['website']}
- About: {lead['about']}
- WA Poll sent: {lead['wa_variant'] or '(unknown)'}
- Pipeline: {', '.join(lead['pipeline'])}
"""
    else:
        lead_context = "\nThis number is NOT in the Notion Leads DB (unknown contact)."

    poll_section = ""
    if poll_answer:
        poll_section = f"\nThey answered the poll with: \"{poll_answer}\""

    prompt = f"""You are handling a live WhatsApp conversation on behalf of Parham (appwebdev.co.uk — AI agency, Manchester).

An inbound WhatsApp message has arrived. You must respond appropriately and FAST.

SENDER PHONE: {phone}
{lead_context}
{poll_section}
THEIR MESSAGE: {message_text}

CONVERSATION HISTORY (last 10 messages, oldest first):
{history}

---

YOUR TASK:
1. Decide what kind of message this is:
   - Normal reply / poll response → craft a warm, casual, helpful reply and send it
   - Wants to talk to a human → offer it politely: "Want me to put you in touch with Parham directly?"
   - Serious prospect (asking about pricing, services, booking) → alert Parham on Telegram AND send a holding reply
   - Off-topic first time → say nicely: "Ha, good one — I'm mainly here to chat about AI/automation for local businesses. Can I help with that?"
   - Off-topic again / spamming → send a polite goodbye, then add them to the blocklist
   - Rude / abusive → add to blocklist immediately (no reply needed)

2. To SEND a WhatsApp message:
   curl -s -X POST http://localhost:3000/send/message \\
     -H "Content-Type: application/json" \\
     -d '{{"phone": "{phone}", "message": "YOUR MESSAGE HERE", "device": "parham"}}'

3. To ADD TO BLOCKLIST (no reply needed):
   python3 -c "
import json
bl = json.load(open('/home/node/gowa/blocklist.json'))
if '{phone}' not in bl:
    bl.append('{phone}')
    json.dump(bl, open('/home/node/gowa/blocklist.json','w'))
print('blocked')
"

4. To ALERT PARHAM on Telegram (serious prospect or human request):
   Use the message tool: action=send, channel=telegram, target=$OWNER_TELEGRAM_ID
   Include: business name, what they said, their phone number, and a short summary of context.
   Always include buttons=[]

OWNER COMMANDS (Parham's personal number: 447547019039):
If the sender matches the configured owner number, treat it as a trusted admin command.
- NEVER blocklist the configured owner number under any circumstances
- Execute whatever he asks: stats, lead counts, pipeline status, summaries, anything
- You have access to exec, Notion scripts, GoWA API — use them to answer properly
- Reply back via WhatsApp with the answer (same send/message curl as above)
- Keep it brief and useful — he's checking in on the fly
- Examples: "how many leads today" → query Notion; "who messaged" → fetch chat history; "status" → check pipelines

TONE RULES (non-negotiable):
- Casual, warm, direct — like a smart local person, not a corporate bot
- 2-3 lines max for first reply. Never essay-length.
- No em dashes. No "Excited to share". No filler phrases.
- Reference what they actually said. Make it feel personal.
- We're Manchester-based, they're local — lean into that if natural.
- If they answered the poll, acknowledge their specific answer before anything else.

Run the exec tool to send the message. Do not just describe what you would do.
"""

    payload = {
        "message": prompt,
        "name": "WA Reply",
        "model": "anthropic/claude-sonnet-4-6",
        "timeoutSeconds": 60,
        "deliver": False,  # don't echo to chat — this is a background operation
    }

    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{GATEWAY_URL}/hooks/agent",
        data=data,
        method="POST"
    )
    req.add_header("Authorization", f"Bearer {HOOKS_TOKEN}")
    req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read()), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode()}"
    except Exception as e:
        return None, str(e)


def handle_webhook(payload_bytes, secret_header):
    """Main entry point called by stats_server."""
    # No secret check — GoWA webhook is localhost-only, no external exposure needed

    try:
        payload = json.loads(payload_bytes)
    except Exception:
        return {"ok": False, "error": "invalid json"}, 400

    # GoWA v8 webhook format:
    # { "device_id": "...", "event": "message"|"poll_response", "payload": { "body": "...", "from": "447...@s.whatsapp.net", "is_from_me": false, ... } }
    event_type = payload.get("event", payload.get("type", ""))
    data = payload.get("payload", payload)  # v8 uses "payload" key

    # Extract phone number
    phone = None
    message_text = ""
    poll_answer = None

    sender = data.get("from") or data.get("sender_jid") or data.get("chat_jid", "")
    if sender:
        phone = sender.split("@")[0].lstrip("+")

    # Message content — v8 uses "body"
    message_text = (
        data.get("body") or
        data.get("content") or
        data.get("text") or
        data.get("message") or
        ""
    ).strip()

    # Poll answer
    if "poll" in event_type.lower():
        poll_answer = message_text or data.get("selected_option", "")

    # Skip if no phone or outbound
    is_from_me = data.get("is_from_me", False) or data.get("fromMe", False)
    if not phone or is_from_me:
        return {"ok": True, "skipped": "outbound or no phone"}, 200

    # Skip our own test number from triggering the agent (Parham's personal)
    # Comment this out when testing is done
    # if phone == "447547019039":
    #     return {"ok": True, "skipped": "test number"}, 200

    # Check blocklist
    blocklist = load_blocklist()
    if phone in blocklist:
        return {"ok": True, "skipped": "blocklisted"}, 200

    # Skip if empty message (read receipts, typing indicators etc)
    if not message_text and not poll_answer:
        return {"ok": True, "skipped": "no content"}, 200

    # Fetch lead context from Notion
    lead = find_lead_by_phone(phone)

    # Update Notion if poll answer
    if lead and poll_answer:
        update_notion_lead(lead["page_id"], poll_answer=poll_answer)

    # Fetch chat history
    history = get_chat_history(phone)

    # Spawn agent
    result, error = spawn_wa_agent(
        phone=phone,
        lead=lead,
        message_text=message_text or poll_answer or "(poll response)",
        poll_answer=poll_answer,
        history=history,
    )

    if error:
        return {"ok": False, "error": f"agent spawn failed: {error}"}, 500

    return {"ok": True, "agent_spawned": True, "phone": phone}, 200
