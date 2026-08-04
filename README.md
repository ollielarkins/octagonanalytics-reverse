# Octagon Recruitment Analytics Platform

A live analytics platform on top of **RecruitCRM**. It replaces manual spreadsheet
reporting with an always-current mirror of the firm's recruitment data, exposed two
ways: **dashboards** for viewing, and **Claude** as a direct interface that answers
questions and performs a small set of defined, audited write-back actions.

> **Guiding principle:** *trustworthy reads before writes.* Get the data model right →
> sync RecruitCRM into it reliably → define every metric once → show it (dashboards) and
> let Claude answer from it → then, carefully, let Claude act back into RecruitCRM.

See [`PROJBRIEF.MD`](PROJBRIEF.MD) for the full brief, [`ROADMAP.MD`](ROADMAP.MD) for the
milestone plan, and [`docs/DECISIONS.md`](docs/DECISIONS.md) for the design-decision log.

---

## Architecture

```
   RecruitCRM  ──sync──▶  Supabase (Postgres mirror)  ──▶  Semantic layer (SQL views)
  (system of              incremental every 2 min           one canonical definition
   record)                nightly soft-delete reconcile      per metric
       ▲                                                          │
       │                                            ┌─────────────┴─────────────┐
       │                                            │                           │
       └────────── write-back ──────────────  Claude (MCP connector)      Dashboard
                   (preview→confirm→audit)     read + gated write         (JSON API + static page)
```

- **RecruitCRM is the single source of truth** ([D8](docs/DECISIONS.md)). Supabase is a
  live mirror; everything downstream reads the mirror. Writes go **back to RecruitCRM**,
  never to the mirror — the mirror catches up via sync (plus an immediate write-through).
- **One semantic layer.** Dashboards and Claude read the *same* canonical views/functions,
  so their numbers can never disagree.
- **Owner attribution.** Per-consultant figures credit the **owning consultant of the job**,
  not whoever logged the event ([D9](docs/DECISIONS.md)).

---

## Live scale (as-built)

| Entity | Rows |
|---|---|
| consultants | 21 |
| clients | 4,582 |
| jobs | 5,968 |
| candidates | ~9,515 |
| candidate_stage_events | 16,536 |

**2026 is the reliable reporting window** — hiring-stage logging before 2026 is sparse, so
firm figures default to a 2026-onward window. This is a data-entry reality in RecruitCRM,
not a platform limitation (see [D8](docs/DECISIONS.md) and the leg-A finding below).

---

## Repository layout

```
supabase/
  migrations/       0000–0014, version-controlled schema + semantic layer + functions
  functions/
    recruitcrm-sync/    the sync engine (backfill | incremental | reconcile | history)
    dashboard-data/     public JSON API returning dashboard_json() (aggregates, no PII)
    octagon-mcp/        the MCP connector: 4 tools (2 read, 2 write)
web/
  dashboard.html      static page that renders dashboard-data (host anywhere static)
docs/
  DECISIONS.md        the design-decision log (D1–D9)
.claude/
  hooks/session-start-dashboard.sh   makes each new chat open with the live dashboard
  settings.local.json
PROJBRIEF.MD, ROADMAP.MD
```

---

## Supabase project

- **Project ref:** `kzcmssldvtjnbwwunuwm` · region `eu-west-1` (GDPR — candidate PII stays in-region)
- **Name:** "Reporting for CRM" · Postgres 17

### Edge functions

| Function | `verify_jwt` | Purpose |
|---|---|---|
| `recruitcrm-sync` | true | Sync engine. Modes: `backfill`, `incremental`, `reconcile`, `history`. Invoked by cron / server-side. |
| `dashboard-data` | false | Public JSON API — `dashboard_json()` aggregates only, no PII. Feeds `web/dashboard.html`. |
| `octagon-mcp` | false | Remote MCP server (Streamable HTTP / JSON-RPC 2.0). Tools below. |
| `recruitcrm-probe` | true | **Throwaway** diagnostic, locked + gutted. Safe to delete. |
| `dashboard` | false | **Defunct** early attempt (Supabase can't serve HTML — see below). Safe to delete. |
| `storage-upload` | true | **Throwaway**, locked. Safe to delete. |

**Public URLs**
- Data API: `https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/dashboard-data`
- MCP connector: `https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp`

### MCP tools (`octagon-mcp`, v3)

| Tool | Kind | What it does |
|---|---|---|
| `get_dashboard` | read | `dashboard_json()` — KPIs, funnel, monthly, per-consultant, pipeline, **sync health**. |
| `funnel_report` | read | Owner-attributed funnel + conversion ratios; filter by date/consultant/team. |
| `client_report` | read | Per-client (account) activity, open/total jobs, CV→placed rate, ranked. |
| `time_to_fill` | read | Days from job open → first placement: firm avg/median + per-consultant. |
| `cold_jobs` | read | Open roles with no candidate activity in N days (default 14). No PII. |
| `placements_report` | read | Placed count (event-stream) + Won revenue, by consultant/client. |
| `consultant_leaderboard` | read | Consultants ranked by placed / cv_sent / first_interview. |
| `update_hiring_stage` | **write** | Moves a candidate's hiring stage in RecruitCRM (`create_placement` on Placed). |
| `assign_candidate` | **write** | Assigns a candidate to a job in RecruitCRM. |

**MCP prompts** (one-click templates via `prompts/list`): `weekly_team_review`,
`my_cold_roles` (arg: consultant), `client_health` (arg: client), `month_in_review`
(arg: month `YYYY-MM`). Each expands into an instruction that drives the read tools above.

**Authentication (per-user bearer tokens).** *Every* tool call must present a valid token
(`Authorization: Bearer <t>`, `x-octagon-token` header, or `auth_token` arg). Tokens map to a
consultant via `mcp_tokens` and are stored only as SHA-256 hashes. This closes read access to
the public and — crucially — the **acting identity is derived from the token server-side**, so
it can't be spoofed by a tool argument (protecting the audit trail). `can_write` is per token,
so write access is granted/revoked per person.

**Write safety.** A write requires a token with `can_write=true`. Every write is: two-phase
**preview → confirm**; **optimistic concurrency** (`expected_status_id` — refuses if the live
stage changed since preview); an **audit_log** insert (who/what/when/before→after); then a
**write-through** re-pull of `/history` so the mirror updates within seconds. `updated_by` is
the token's consultant id, so the action is attributed in RecruitCRM's own activity log.

---

## Secrets (set in Supabase, never in the repo)

| Secret | Used by | Notes |
|---|---|---|
| `RECRUIT_CRM_API_TOKEN` | `recruitcrm-sync`, `octagon-mcp` | Account-level RecruitCRM Open API token (Business+ plan, Account-Owner-only). ~120 chars. **Never paste into chat.** |

Access to the connector is by **per-user token** (table `mcp_tokens`), not a server secret —
see *Access tokens* below. (The old `OCTAGON_WRITE_KEY` shared-secret gate was replaced by
per-user tokens in v3 and is no longer used.)

`.gitignore` excludes `.env`, `*.key`, and `secrets/`.

---

## Migrations

Applied in order (`supabase/migrations/`):

| # | Name | What it does |
|---|---|---|
| 0000 | baseline_tables | Reconstruction of the hand-built 8-table schema |
| 0001 | structural_fixes | `jobs.slug` + unique index; `stage_lookup`; `reporting_exclusions`; `audit_log`; RLS + `authenticated` read policies on all tables (fixes the `deal_stage_events` gap) |
| 0002 | canonical_semantic_layer | Moves 19 legacy views → `legacy` schema; builds 15 canonical `security_invoker` views over `v_candidate_events` |
| 0003 | review_fixes | Fixes `client_funnel` fan-out (`distinct on (job_slug)`); revokes `legacy` from anon/authenticated |
| 0004 | sync_state_and_extensions | `pg_cron`, `pg_net`, `sync_state` table |
| 0005 | schedule_incremental_sync | Incremental-sync cron (now `*/2 * * * *`) |
| 0006 | soft_delete_reconcile | `deleted_at` columns + `reconcile_entity()` RPC (refuses empty id sets) |
| 0007 | schedule_reconcile | Nightly reconcile crons (03:00 / 03:10 / 03:20) |
| 0008 | candidates_and_stage_lookup | `candidates` table + confirmed stage-id mappings |
| 0009 | views_exclude_soft_deleted | Views filter `deleted_at is null` |
| 0010 | lock_down_reconcile_rpc | Revoke `reconcile_entity` from public/anon/authenticated; grant service_role |
| 0011 | history_backfill_prep | Cursor column; truncate + unique natural key on `candidate_stage_events` |
| 0012 | schedule_history_backfill | (temporary backfill cron — since unscheduled) |
| 0013 | dashboard_json_function | `dashboard_json()` — all dashboard aggregates as one jsonb |
| 0014 | funnel_report | `funnel_report()` — owner-attributed funnel behind the MCP read tool |
| 0015 | sync_watchdog | `sync_health()` classifier; `check_sync_health()` watchdog + `sync_alerts`/`app_settings`; embeds health in `dashboard_json()`; 5-min cron |
| 0016 | mcp_read_functions | `client_report`, `time_to_fill`, `cold_jobs`, `placements_report`, `consultant_leaderboard` |
| 0017 | mcp_auth | `mcp_tokens` (hashed per-user tokens) + `mint_mcp_token()` admin helper |

### Cron schedule

| When | Job |
|---|---|
| every 2 min | incremental sync (RecruitCRM → mirror) |
| every 5 min | sync-health watchdog (`check_sync_health`) |
| 03:00 / 03:10 / 03:20 nightly | soft-delete reconcile (consultants / clients / jobs) |

Freshness: edits show in the mirror within ~2 min (or seconds after a Claude write-through).
Hard deletes propagate at the nightly reconcile.

---

## Key findings (why the numbers are what they are)

1. **The spreadsheet is a validation reference, not a source of truth** ([D8](docs/DECISIONS.md)).
   The "Ratios 2025-26" sheet is a *manual tally* the CRM never contained. Diagnostic over
   120 candidates found only 11 distinct statuses; unmapped ones (Assigned, Shortlist, Applied)
   are not funnel stages. **Ratios match** the sheet (~0.21–0.36 both); **absolute counts don't**
   (e.g. Jan 2025: mirror 107 vs sheet 223) because the pre-2026 activity was never logged in
   RecruitCRM. Closing that gap is a data-entry/process fix — the platform reports the CRM figure.
2. **Owner attribution, not `updated_by`** ([D9](docs/DECISIONS.md)). Crediting whoever logged
   an event produced impossible funnels (one consultant credited with 62 CVs / 289 first
   interviews). Per-consultant figures credit the owning consultant of the job.
3. **Supabase cannot serve HTML.** Both edge functions and public storage are forced to
   `Content-Type: text/plain` + `CSP: default-src 'none'; sandbox`, so a browser shows raw
   source. The dashboard is therefore a **JSON API** (`dashboard-data`) plus a **separately-hosted
   static page** (`web/dashboard.html`) — not an HTML edge function.
4. **~39% of jobs have an unresolved `client_id`** — they reference companies absent from the
   `/companies` listing (likely archived). Known gap, low impact on funnel metrics.

---

## Setup / operations

**Run a sync manually** (server-side / service role):
```bash
# incremental (what the cron runs)
curl -X POST "https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=incremental"
```

**Access tokens** (admin, per user). Mint in the Supabase SQL editor — the plaintext is
returned once and only its hash is stored:
```sql
-- read-only token for a recruiter (find the id via GET /v1/users or the consultants table)
select public.mint_mcp_token(<recruitcrm_user_id>, 'Keelan – read', false);
-- write-enabled token
select public.mint_mcp_token(<recruitcrm_user_id>, 'Keelan – write', true);
```
Give each recruiter their token to paste into the connector's auth field. Revoke with
`update mcp_tokens set active=false where label='…';`.

**Enable write-back** (admin): mint a token with `can_write=true` (above) and test one real
write on a **safe** candidate/job first. There is no longer a global write switch — write
access is per token.

**Sync alerts** (admin, optional): to get pinged on a sync stall, set a Slack/Discord webhook:
```sql
update app_settings set value='https://hooks.slack.com/…' where key='alert_webhook_url';
```
The 5-min watchdog posts on critical/recovery. Without a webhook it still logs to `sync_alerts`
and the dashboard shows a staleness banner.

**Roll the connector out to the team** (admin, in claude.ai):
1. Add the `octagon-mcp` URL as an **org connector** (Settings → Connectors); each member
   authorizes it with their own token.
2. Create a **shared Project** whose instructions say *"at the start of each chat call
   `get_dashboard` and present it."*

---

## Status vs the roadmap

| Milestone | Status |
|---|---|
| M0 Foundations & access | ✅ Done (Business plan, EU region, token, migrations) |
| M1 Data model | ✅ Done (0000–0001) |
| M2 Ingestion / sync | ✅ Done (backfill + incremental + reconcile + history) |
| M3 Semantic layer | ✅ Done (15 canonical views, 0 security lints) |
| M4 Dashboards | ✅ Done (JSON API + static page + session-start auto-render) |
| M5 Claude query layer | ✅ Done — 7 read tools + 4 prompts, per-user auth |
| M6 Claude action layer | ⚠️ Built + auth'd (per-user write tokens) — one live write test still not run |
| M7 Hardening & rollout | ◻️ Partial — ✅ per-user auth, ✅ sync monitoring/alerts; connector rollout + throwaway-function cleanup outstanding |
