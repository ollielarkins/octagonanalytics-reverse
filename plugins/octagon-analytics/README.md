# Octagon Analytics (Claude Code plugin)

Live RecruitCRM recruitment analytics for Octagon recruiters, delivered through Claude Code. Reads
the same vetted metrics layer as the dashboards, so the numbers always agree.

## What it installs

- **The Octagon connector** (`octagon-analytics`, a remote MCP server) — all read tools
  (dashboard, funnel, client, time-to-fill, cold jobs, placements, leaderboard, BD, find candidate,
  job pipeline, stalled, my-day, match candidates, call activity) and the gated write actions.
- **Slash commands** — `/octagon-analytics:dashboard` and `/octagon-analytics:kpi`.
- **SessionStart hook** — opens each chat with the live dashboard.

## Requirements

You need an Octagon access token (an admin mints one). Set it before launching Claude Code:

```bash
export OCTAGON_MCP_TOKEN="your-token-here"
claude
```

On Windows PowerShell:

```powershell
$env:OCTAGON_MCP_TOKEN = "your-token-here"
claude
```

## Install

```bash
/plugin marketplace add ollielarkins/octagonanalytics-reverse
/plugin install octagon-analytics@octagon
```

See the repo `ONBOARDING.md` for the full walk-through.
