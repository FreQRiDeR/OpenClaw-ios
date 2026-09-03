<p align="center">
  <img src="resources/app-icon.PNG" width="120" alt="OpenClaw iOS">
</p>

<h1 align="center">OpenClaw for iOS & macOS</h1>

<p align="center">
  A native control room for the <a href="https://github.com/openclaw/openclaw">OpenClaw</a> AI gateway.<br>
  Monitor, trace, chat, and manage your agent — from your phone or Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/iOS-17%2B-blue?logo=apple" alt="iOS 17+">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-Charts-purple?logo=swift" alt="SwiftUI">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/Dependencies-1-brightgreen" alt="Dependencies">
  <img src="https://img.shields.io/badge/Code-100%25%20AI%20Generated-blueviolet" alt="AI Generated">
  <img src="https://img.shields.io/badge/Status-Active%20Development-yellow" alt="Active Development">
</p>

---

## The Story

Hi, I'm **Parham** — Manchester-based software developer with 12+ years of experience. Technical Lead at [Kitman Labs](https://www.kitmanlabs.com) by day, OpenClaw and AI enthusiast by night. Manchester, UK

I've been deep in AI for the last three years, and [OpenClaw](https://github.com/openclaw/openclaw) genuinely impressed me — it was the missing piece for automating my workflows and being dramatically more productive. Here's one of my earlier cron schedules in Google Calendar (it's much crazier now):

<p align="center">
  <img src="resources/openclaw-calendar.PNG" width="700" alt="OpenClaw Cron Schedule in Google Calendar">
</p>

But as a technical person myself, I found the onboarding, setup, and control UI wasn't OpenClaw's best feature. The engine, the brain, how it works — that's extraordinary. The UX? Not so much.

**Swift and iOS are my specialty**, so I built this. The main reasons:

- **Tracing** — cron runs get crazy in logs. Being able to drill down to any trace step and ask the agent to investigate a warning or error should be much easier than the web control UI
- **Comments on everything** — see a memory file that needs updating? Comment on a paragraph. See a trace step that looks wrong? Comment on it. The agent reads your comments and acts. This is the missing piece
- **Mobile-first control** — pull down to refresh, tap to investigate, chat with your agent while on the go

---

## Demo

<p align="center">
  <a href="https://drive.google.com/file/d/1dC7TLsp8c-fUoj3i7hPodQ-uzzt8ngfw/view?usp=sharing">
    <img src="resources/IMG_2548.PNG" width="250" alt="Watch Demo">
  </a>
</p>

<p align="center"><a href="https://drive.google.com/file/d/1dC7TLsp8c-fUoj3i7hPodQ-uzzt8ngfw/view?usp=sharing">Watch the 3-minute demo on Google Drive</a></p>

---

## Screenshots

<p align="center">
  <img src="resources/IMG_2548.PNG" width="220" alt="Home Dashboard">
  <img src="resources/IMG_2544.PNG" width="220" alt="Cron History">
  <img src="resources/IMG_2546.PNG" width="220" alt="Memory & Skills">
</p>

<p align="center">
  <img src="resources/IMG_2547.PNG" width="220" alt="Execution Trace">
  <img src="resources/IMG_2550.PNG" width="220" alt="Sessions">
  <img src="resources/IMG_2545.PNG" width="220" alt="Schedule Timeline">
</p>

<p align="center">
  <img src="resources/IMG_2549.PNG" width="220" alt="Doctor Output">
</p>

---

## Features

### Dashboard
Core cards: System Health (ring gauges, 15s polling), Commands (12 quick actions with parsed output + AI investigation), Cron Summary, Token Usage (charts, pipeline attribution). Optional cards (Outreach Stats, Blog Pipeline) appear automatically if the gateway provides those endpoints — hidden gracefully otherwise.

### Cron Management
Full job list with status badges. Segmented Cron Jobs / History. 24-hour schedule timeline. Detail view with: purpose, model, schedule, stats (avg duration, tokens, success rate), paginated run history. One-tap "Investigate with AI" on errors.

### Execution Traces
Step-by-step agent traces: system prompts, thinking, tool calls, tool results, responses. Metadata pills (model with provider icon, tokens). **Comment on any step** — queue comments, batch submit, agent investigates with full session context.

### Memory & Skills
Browse all workspace files. Paragraph-level markdown viewer with **Figma-style comments** — annotate paragraphs, submit to agent for edits. Skills: browse folder trees, read SKILL.md with comments, view scripts/config read-only. Skill-level comments instruct agent to read `create-skill` best practices first. Maintenance actions: Full Cleanup, Today Cleanup.

### Streaming Chat
SSE streaming chat with the orchestrator agent. Session-bound (server manages history). Chat bubbles with markdown, timestamps, copy. Auto-scroll, stop button, interactive keyboard dismiss.

### Sessions
Main session hero card with context window ring gauge. Subagent list. Both link to execution traces.

### Command Output Parsers
Custom parsed views for: **Tail Logs** (level-filtered structured entries), **Security Audit** (severity badges, collapsible findings with fixes), **Doctor** (collapsible sections, status lines), **Status** (table sections), **Channel Status** (probe cards). Raw monospace fallback for others.

### Admin
Models & Config (provider icons, fallbacks, aliases). Channels (status dots, provider usage bars). Tools & MCP (native tool groups, MCP server detail with lazy-loaded tool lists). All 15 exec commands.

---

## Getting Started

### 1. Install the stats server on your OpenClaw machine

The app talks to a small **stats server** (Python, port 8765) that sits next to your gateway and provides the `/stats/*` endpoints — system health, token usage, memory & skills, and the allowlisted admin commands. Without it only Chat, Sessions and Automations work.

One command on the machine that runs your gateway — **no skill, no agent involvement**:

```bash
curl -fsSL https://raw.githubusercontent.com/FreQRiDeR/OpenClaw-ios/main/install.sh | bash
```

Or from a clone of this repo: `bash install.sh`

It will:
1. check prerequisites (`openclaw`, `python3`, `tailscale`) and read the gateway token from `~/.openclaw/openclaw.json`
2. warn about any gateway config the app needs (see step 2) — it never edits your config
3. install to `~/.openclaw/openclaw-stats-server` (from the repo, the bundled `docs/openclaw-stats-server.zip`, or a download)
4. start the server and confirm `/stats/health` answers with your token
5. configure `tailscale serve` so `/` → gateway and `/stats` → stats server, then probe every endpoint the app uses
6. print the exact **Gateway URL** and **Agent ID** to type into the app

Options: `--no-tailscale` (nginx / LAN instead), `--dest DIR`, `--force`.

> **Why the path split matters:** the app uses one base URL for everything. If your proxy only maps `/` to the gateway, `/stats/*` lands on the gateway and you'll see *"Data couldn't be read because it isn't in the correct format"* (System Health) or *"HTTP 404 Not Found"* (Memory & Skills, Tools, Tokens). The app detects this and tells you to run the installer.

<details>
<summary>Day-to-day commands (the server does not auto-start on reboot, by design)</summary>

```bash
S=~/.openclaw/openclaw-stats-server
bash $S/scripts/dashboard/ensure_stats_server.sh --force   # start / restart
pkill -f stats_server.py                                    # stop
bash $S/scripts/setup_tailscale.sh --verify                 # health-check every endpoint
tail -f /tmp/stats_server.log                               # logs
```
</details>

More detail in [openclaw-stats-server/README.md](openclaw-stats-server/README.md).

### 2. Configure the gateway

The installer checks these for you and warns if anything is missing. Add to `openclaw.json`:

```json
{
  "tools": {
    "sessions": { "visibility": "all" },
    "profile": "full",
    "allow": ["exec", "cron", "gateway", "sessions_list", "sessions_history", "memory_get"]
  },
  "gateway": {
    "http": {
      "endpoints": {
        "chatCompletions": { "enabled": true }
      }
    }
  }
}
```

### 3. Build and run the app

1. **Clone** this repo
2. **Open** `OpenClaw.xcodeproj` in Xcode 16+
3. **Build and run** on a simulator or device (iOS 17+)
4. **On first launch**, enter your gateway URL (e.g. `https://your-server.com:18789`), Bearer token and **Agent ID** — this must match `openclaw agents list` (`main` on a stock install); a wrong ID means empty chat history
5. The dashboard loads automatically — pull down to refresh

### Security

All communication is **direct between your phone and your gateway** — no third-party servers, no telemetry, no data collection. Your Bearer token is stored in the iOS Keychain (never in UserDefaults or iCloud). The app makes authenticated HTTPS requests only to the gateway URL you configure. No one else sees your data.

---

## Architecture

Clean Architecture with MVVM per feature. 135 files, ~11,000 lines.

```
View → LoadableViewModel<T> → Repository protocol → GatewayClientProtocol → URLSession
                                      ↓
                                 MemoryCache (actor, TTL)
```

- **Swift 6** concurrency: `@Observable`, `@MainActor`, strict `Sendable`
- **Design system**: `Spacing`, `AppColors`, `AppTypography`, `AppRadius`, `Formatters`
- **Shared components**: `ModelPill`, `ProviderIcon`, `DetailTitleView`, `CommentSheet`, `CommentInputBar`, `CopyButton`, `ElapsedTimer`, `TokenBreakdownBar`
- **One external dependency**: [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)

See [CLAUDE.md](CLAUDE.md) for the full architecture guide, conventions, and API gotchas.

---

## API

All requests go to your configured gateway URL with `Authorization: Bearer <token>`.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/stats/system` | CPU, RAM, disk, uptime |
| GET | `/stats/tokens?period=` | Token usage with model breakdown |
| POST | `/stats/exec` | Run allowlisted commands |
| POST | `/tools/invoke` | Gateway tool calls (cron, sessions, memory) |
| POST | `/v1/chat/completions` | Chat streaming (SSE) + agent prompts |

<details>
<summary>Full command list</summary>

**Action commands**: `doctor`, `status`, `logs`, `security-audit`, `backup`, `channels-status`, `config-validate`, `memory-reindex`, `session-cleanup`, `plugin-update`

**Workspace commands**: `memory-list`, `skills-list`, `skill-files`, `skill-read`

**Admin commands**: `models-status`, `agents-list`, `channels-list`, `tools-list`, `mcp-list`, `mcp-tools`
</details>

---

## AI-Generated

100% of the code in this repository was generated by AI (Claude Code). Every file, every view, every parser — written through conversation, not by hand. The architecture, patterns, and conventions were designed collaboratively but the implementation is entirely AI-authored.

## Platforms

- **iOS 17+** — tab-based navigation, haptic feedback, interactive keyboard dismiss
- **macOS 14+** — sidebar navigation, native clipboard, resizable window (min 800x500)

Same codebase, same features. Platform differences handled with `#if os(iOS)` / `#if os(macOS)` guards (~30 lines total).

## Roadmap

If this project gets enough traction, the long-term plan is to migrate to **Kotlin Multiplatform (KMP)** for shared data and business logic layers, expanding to more platforms:

- **iOS + macOS** — SwiftUI (current, shipping)
- **Android** — Jetpack Compose
- **Shared** — Kotlin Multiplatform for networking, repositories, DTOs, and business logic

### Future: Semantic Memory Search

The `memory_search` tool is available via `/tools/invoke` but requires an embedding provider (OpenAI, Google, Voyage, or Mistral API key) to be configured on the server. Once enabled, semantic search can be added to the Memory tab.

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

MIT

---

<p align="center">
  Built with <a href="https://claude.ai/code">Claude Code</a> by <a href="https://github.com/parham-dev">Parham</a>
</p>
