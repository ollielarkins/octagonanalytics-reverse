# Octagon Analytics

Live recruitment analytics on top of RecruitCRM, with a Claude interface recruiters use directly to
ask questions and take defined actions.

RecruitCRM stays the system of record. This platform mirrors it into Supabase, defines every metric
exactly once, and serves those definitions to both the dashboards and Claude — so the two can never
disagree.

> [!WARNING]
> **`dashboard-data` is unauthenticated and this repo is public.** Firm revenue and every
> consultant's individual figures are readable by anyone with the URL. See
> [Architecture](Architecture#dashboard-data-is-unauthenticated). Open as of 15/09/2026.

---

## I want to…

| | Go to |
|---|---|
| Get set up and connected | [Onboarding](Onboarding) → Part 1 |
| See every slash command | [Commands](Commands) |
| Know what I can ask it | [Tools Reference](Tools-Reference) |
| Understand what a number counts | [Metrics and Definitions](Metrics-and-Definitions) |
| Check whether a number can be trusted | [Data Caveats](Data-Caveats) |
| Work out why something looks wrong | [Data Caveats](Data-Caveats), then [Runbook → Incidents](Operations-Runbook#incidents--10082026) |
| Deploy, backfill, or mint a token | [Operations Runbook](Operations-Runbook) |
| Understand how the data flows | [Architecture](Architecture) |

## The pages

| Page | For |
|---|---|
| **[Onboarding](Onboarding)** | Getting set up and productive. Start here if you're a recruiter. |
| **[Commands](Commands)** | All 57 slash commands, grouped by what you are trying to do. |
| **[Tools Reference](Tools-Reference)** | Every question the system can answer, and how to ask it. |
| **[Metrics and Definitions](Metrics-and-Definitions)** | What each number actually means. Read before quoting anything. |
| **[Data Caveats](Data-Caveats)** | Where the numbers are soft, and why. Read this second. |
| **[Architecture](Architecture)** | How data gets from RecruitCRM to your screen. |
| **[Operations Runbook](Operations-Runbook)** | Deploys, backfills, tokens, incidents. Admins only. |

---

## Current state — 15/09/2026

Live and in use. The write path is broad — jobs, deals, candidates, companies, contacts, pitches,
meetings, tasks, hotlists, email and deletions — and **has now been used**: `audit_log` holds 44
entries, the first real writes landing 12–20/08/2026 (21 hiring-stage moves, 9 candidates, 6
contacts). Every write stays two-step: preview, then an explicit confirm.

### The platform

| | |
|---|---|
| Connector | octagon-mcp 3.44.0 — 50 tools, 26 prompts |
| Commands | 57 slash commands, all exercised 15/09/2026 |
| Sync | 13 feeds, health-monitored, plus a cron manifest watchdog |
| Webhooks | 15 subscriptions, including the four `*.deleted` events |
| Active tokens | 5 — four people plus one OAuth session |

### The data

| | |
|---|---|
| Candidates | 52,158 (19,500+ with pipeline activity) |
| Jobs | 6,025 (142 open) |
| Clients | 4,703 |
| Deals | 1,642 |
| Notes | 100,271, 2018 onward |
| Devyce calls | 10,331 — but only from 13/03/2026, and see the warning below |
| Off limit | 87 in RecruitCRM, all flagged here — excluded from shortlists |

> [!CAUTION]
> **Call categorisation is falling and the BD/client call KPIs depend on it.** 26% in May, 9% in
> September. Those targets are measured only from *categorised* Devyce calls, so they now understate
> reality by roughly ten to one. See [Data Caveats](Data-Caveats#call-categorisation).

### What changed on 15/09/2026

The live sync had not run since 10/09. The cause was not a failing job: the `pg_cron` entries were
gone from the database entirely, including the watchdog that would have reported it. Because each
entity kept its last good `sync_state` row, health showed "stale" rather than "dead" for five days.

Restored, and hardened against the same class of failure:

- All eight missing cron jobs are back, and `cron_manifest` now declares the expected 18 so a missing
  or drifted job is alerted rather than silently absent.
- `reconcile_deals` hard-deleted rows — a plain `DELETE` against the table holding billing. It now
  tombstones like every other entity.
- Deleted records were never actually hidden: `delete_record` tombstoned them but no read path
  checked `deleted_at`, so a deleted candidate still came back in search and could still be matched
  to a job. Now hidden from operational surfaces, deliberately left in history.
- Webhook payloads were being routed to the wrong entity — 68 job and 16 company payloads were
  spent refreshing candidates. Fixed, and deletions now tombstone on arrival.

---

## Ground rules

1. **RecruitCRM is the system of record.** Writes go there; the mirror catches up via the normal
   sync. Never edit the mirror to "fix" a number.
2. **One definition per metric.** If a figure appears in two places it comes from the same view or
   RPC. Never write ad-hoc logic against the raw tables.
3. **Candidate names are PII.** Internal only. Not client-facing unless already shared with that
   client. No bulk export.
4. **Never invent a number.** If the data can't answer, say so.
