# Octagon Analytics (Claude Code plugin)

Live RecruitCRM recruitment analytics for Octagon recruiters, delivered through Claude Code. Reads
the same vetted metrics layer as the dashboards, so the numbers always agree.

## What it installs

- **The Octagon connector** (`octagon-analytics`, a remote MCP server) — all read tools
  (dashboard, funnel, client, time-to-fill, cold jobs, placements, leaderboard, BD, find candidate,
  job pipeline, stalled, my-day, match candidates, call activity) and the gated write actions.
- **Slash commands** — 56 of them, covering every connector tool. Run `/` to browse.

  | Group | Commands |
  |---|---|
  | Overview | `/dashboard` `/kpi` `/myday` `/dayplan` `/week` `/eod` `/yesterday` |
  | Funnel & performance | `/funnel` `/leaderboard` `/account` `/timetofill` `/rejections` `/placements` `/fees` `/billing` |
  | Attention | `/chase` `/stalled` `/coldjobs` `/unbooked` `/feedback` `/jobstatus` |
  | Activity | `/evening` `/visits` `/newjobs` `/noteskpi` `/bd` `/pitches` |
  | Lookup | `/find` `/pipeline` `/candidate` `/notes` `/files` `/match` `/ref` |
  | Pipeline actions | `/move` `/assign` `/unassign` `/pitch` `/offlimit` `/hotlist` |
  | Records | `/newcandidate` `/editcandidate` `/newjob` `/editjob` `/client` `/note` `/delete` |
  | Money | `/won` `/newdeal` |
  | Diary | `/meeting` `/task` |
  | Writing | `/advert` `/boolean` `/specpitch` `/interviewprep` `/email` |

  Every command that writes to RecruitCRM previews first and applies only on explicit
  confirmation, one record at a time. `/delete` is irreversible and refuses bulk operations.
  `/email` is the only command that leaves the building and defaults to saving a draft.
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
