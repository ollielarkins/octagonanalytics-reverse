# Octagon Recruitment Analytics Platform

For a developer or admin working on the platform: what it is, how the repo is laid out, and how a change reaches production.

*Last reviewed 04/11/2026.*

Octagon Analytics keeps a live mirror of the firm's RecruitCRM data in Supabase, defines every
metric once in SQL, and serves it to recruiters through Claude: a remote MCP connector
(`octagon-mcp`) answers questions, renders the dashboard and report widgets, and makes audited
write-backs to RecruitCRM, while scheduled jobs post briefs, the action queue and coach nudges to
Slack. RecruitCRM stays the system of record; nothing is written to the mirror directly.

**User and operator documentation lives in the [wiki](https://github.com/ollielarkins/octagonanalytics-reverse/wiki).**
This README covers the repository.

On this page: [How it fits together](#how-it-fits-together) ·
[Repository layout](#repository-layout) · [Deploying](#deploying) ·
[Supabase project](#supabase-project) · [Security](#security) · [Operating it](#operating-it) ·
[Key findings](#key-findings) · [Status](#status)

| I want to… | Go to |
|---|---|
| Use the platform as a recruiter | [Onboarding](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Onboarding) |
| Find a command or a tool | [Commands](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Commands), [Tools Reference](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Tools-Reference) |
| Know what a number means | [Metrics and Definitions](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Metrics-and-Definitions) |
| Know where numbers are soft | [Data Caveats](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Data-Caveats) |
| Understand the design | [Architecture](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Architecture), [`docs/DECISIONS.md`](docs/DECISIONS.md) |
| Deploy, backfill, mint a token | [Operations Runbook](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Operations-Runbook), [CONTRIBUTING.md](CONTRIBUTING.md) |
| Set up as an admin or developer | [ONBOARDING.md](ONBOARDING.md) |
| Report a security problem | [SECURITY.md](SECURITY.md) |

---

## How it fits together

```mermaid
flowchart LR
  RC[RecruitCRM<br/>system of record] -- "sync every 1-15 min,<br/>webhooks, hourly reconcile" --> DB[(Supabase Postgres<br/>mirror)]
  DB --> SL[Semantic layer<br/>SQL views + RPCs]
  SL --> MCP[octagon-mcp<br/>connector + widgets]
  SL --> SLK[Slack jobs<br/>briefs, queue, coach]
  MCP <--> C[Claude<br/>recruiters]
  MCP -- "preview, confirm, audit" --> RC
```

- **RecruitCRM is the single source of truth** ([D8](docs/DECISIONS.md)). Writes go back to
  RecruitCRM through its API, then a write-through refresh updates the mirror within seconds.
- **One semantic layer.** The connector, its widgets and the Slack jobs read the same views and
  functions, so their numbers cannot disagree.
- **Activity is credited to the actor**, whoever moved the stage; calls to the caller; billing to
  the deal owner. Leavers keep their history and are tagged "left".
- **2026 is the reliable reporting window.** Hiring-stage logging before 2026 is sparse in
  RecruitCRM, so reports default to 2026 year to date.

## Repository layout

| Path | What is there |
|---|---|
| `supabase/migrations/` | Schema, semantic layer, RPCs, RLS and cron, numbered `0001`–`0148`. Next is `0149` |
| `supabase/functions/octagon-mcp/` | The MCP connector: 80 tools and 26 prompts, the OAuth bridge, MCP Apps widgets (`widgets.ts`, `ext_apps_bundle.ts`). Version 3.99.1 |
| `supabase/functions/recruitcrm-sync/` | The mirror: backfill, incremental, reconcile, history, notes, off-limit, meetings, assignment sweep |
| `supabase/functions/recruitcrm-webhook/` | Near-live change trigger from RecruitCRM; tombstones on `*.deleted` events |
| `supabase/functions/daily-queue/` | 08:30 action queue DMs and the Monday manager exceptions DM |
| `supabase/functions/slack-actions/` | Slack buttons on the queue DMs (Team Briefs app); writes back on Confirm |
| `supabase/functions/coach-dm/`, `coach-actions/` | The Octagon Coach DMs and their buttons (separate Slack app) |
| `supabase/functions/inbox-sync/` | Polls connected Outlook inboxes through Microsoft Graph |
| `supabase/functions/digest-email/` | Builds the scheduled Slack briefs |
| `supabase/functions/slack-command/` | Slack `/dashboard` and `/kpis` |
| `supabase/functions/feedback/` | Issue and feature capture from the connect page |
| `supabase/functions/_shared/` | `caller.ts` (who may call a locked function), `graph.ts` (Microsoft Graph) |
| `supabase/functions/dashboard/`, `dashboard-data/` | Retired 03/11/2026: 410 stubs with no data |
| `supabase/functions/recruitcrm-probe/`, `recruitcrm-discover/` | Throwaway API probes, locked; not part of the product |
| `supabase/config.toml` | `verify_jwt` per function, with the reason for each |
| `web/octagon-connect.html` | The connector's login page (token to OAuth handoff) |
| `scripts/` | Repo checks: widget bundle build, widget and connect-page checks |
| `rollout/` | Org instructions for claude.ai and recruiter templates |
| `slack/` | The Octagon Coach Slack app manifest |
| `plugins/` | Pointer only. The 82 slash commands live in [octagon-plugins](https://github.com/ollielarkins/octagon-plugins) |
| `docs/wiki/` | Source of the GitHub wiki (a separate git repo; see below) |
| `docs/DECISIONS.md` | Append-only design decision log |
| `ROADMAP.MD`, `PROJBRIEF.MD` | Roadmap with current status; the original brief, kept as history |

> [!IMPORTANT]
> `docs/wiki/` is the source for the GitHub wiki, which is a **separate git repository**. Editing a
> page in the GitHub UI does not update this repo, and pushing here does not update the wiki. Edit
> here, then sync deliberately:
> ```bash
> git clone https://github.com/ollielarkins/octagonanalytics-reverse.wiki.git /tmp/wiki
> cp docs/wiki/*.md /tmp/wiki/ && cd /tmp/wiki && git add -A && git commit && git push
> ```

---

## Deploying

> [!WARNING]
> Since 04/11/2026 the Supabase CLI returns 403 for this account (`functions deploy` and
> `db query`). Until that is fixed, migrations and functions go through the **Supabase MCP tools**:
> `apply_migration` and `deploy_edge_function`. Never use `supabase db push`: the local file names
> do not match the remote migration history.

**Migrations.** Apply with `apply_migration`, using the file's name (`0149_short_name`) and its full
contents, then commit the same file. Test risky SQL first; see
[CONTRIBUTING.md](CONTRIBUTING.md#migrations).

**Edge functions.** `deploy_edge_function` uploads file contents, so:

- Send the real files from disk, every one the entrypoint imports: for `octagon-mcp` that is
  `index.ts`, `widgets.ts`, `ext_apps_bundle.ts` and `../_shared/graph.ts`; for a locked function,
  `../_shared/caller.ts`. A placeholder string once took the connector down (10/08/2026).
- Set `verify_jwt` to the value in `supabase/config.toml` for that function. The tool defaults to
  `true`, which would lock out `octagon-mcp`, the webhook and the Slack endpoints.
- Bump `SERVER.version` in `octagon-mcp/index.ts`, then confirm the live build:

```bash
node --experimental-strip-types --check supabase/functions/octagon-mcp/index.ts   # before
curl -s --retry 8 --retry-delay 3 --retry-all-errors \
  https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp               # after: shows the version
```

When a change spans both, apply the migration first, then deploy the function that calls it.

---

## Supabase project

Project "Reporting for CRM", ref `kzcmssldvtjnbwwunuwm`, region `eu-west-1` (candidate PII stays in
the EU), Postgres 17.

| Function | `verify_jwt` | Auth and purpose |
|---|---|---|
| `octagon-mcp` | false | Per-user tokens in `mcp_tokens` (OAuth or bearer). The connector |
| `recruitcrm-sync` | true | Locked: service role or `CRON_SECRET`. The mirror |
| `recruitcrm-webhook` | false | Shared `?key=` secret. Near-live change trigger |
| `daily-queue`, `coach-dm`, `digest-email`, `inbox-sync` | true | Locked: service role or `CRON_SECRET`. Driven by `pg_cron` |
| `slack-actions`, `coach-actions`, `slack-command` | false | Slack request signature, each with its own app's signing secret |
| `feedback` | false | Public form: field validation, length cap, honeypot, per-IP rate limit. Stores submissions, serves no data |
| `dashboard`, `dashboard-data` | false | Retired 03/11/2026. Return 410 Gone and no data |
| `recruitcrm-probe`, `recruitcrm-discover` | true | Throwaway probes |

### Schedule

All times UK. The Slack jobs are scheduled at two UTC hours and send only at the right UK hour, so
they survive the clock change.

| When | Job |
|---|---|
| Every minute | Candidate stage history, the funnel's live feed |
| Every 3 min | Candidate deletion pass drain (passes start 05:40 and 18:40 UTC) |
| Every 5 min | Sync health watchdog; Outlook inbox poll |
| Every 10 min | Cron manifest watchdog: do the scheduled jobs still exist? |
| Every 15 min | Incremental sync of all entities; notes re-walk |
| Hourly | Reconcile clients :05, jobs :12, deals :18; off-limit refresh :25; assignment sweep :40 |
| Daily | Reconcile consultants 03:00 and contacts 03:20; inbox 30-day purge 03:20; meetings refresh 06:10; housekeeping purges |
| 07:30 weekdays | Morning brief to Slack; sync health digest to the admin bot |
| 08:00 Mondays | Week Ahead brief |
| 08:30 weekdays | Action queue DMs (pilot); Mondays also the manager exceptions DM |
| 12:30, 16:45 weekdays; 08:45 Mondays | Octagon Coach DMs (shadow mode) |
| 17:30 weekdays | Day End brief |
| Fridays | Weekly usage table |

Add every new permanent job to `cron_manifest` in the same migration. As of 04/11/2026
`recruitcrm-assignment-sweep` and `weekly-usage-slack` run but are not declared in it.

## Security

The full model is in [SECURITY.md](SECURITY.md). In short: every connector call carries a per-user
token (stored only as a SHA-256 hash) that fixes who is acting; every write is preview then confirm
against a server-stored nonce, audited, and attributed in RecruitCRM via `updated_by`; locked
functions need the service-role key or `CRON_SECRET`; no unauthenticated endpoint has served firm
figures since 03/11/2026.

### Secrets

Set in Supabase function secrets, never in the repo. `.gitignore` excludes `.env`, `*.key` and
`secrets/`.

| Secret | Used by |
|---|---|
| `RECRUIT_CRM_API_TOKEN` | `recruitcrm-sync`, `octagon-mcp`, `slack-actions`, `coach-actions` |
| `CRON_SECRET` | Locked functions, via `_shared/caller.ts`; `pg_cron` sends it from Vault (0132) |
| `WEBHOOK_SECRET` | `recruitcrm-webhook`; `octagon-mcp` when it creates subscriptions |
| `SLACK_SIGNING_SECRET` | `slack-command` |
| `SLACK_BOT_TOKEN`, `SLACK_BRIEFS_SIGNING_SECRET` | `daily-queue`, `slack-actions` (Team Briefs app) |
| `COACH_BOT_TOKEN`, `COACH_SIGNING_SECRET` | `coach-dm`, `coach-actions` (Octagon Coach app) |
| `MS_TENANT_ID`, `MS_CLIENT_ID`, `MS_CLIENT_SECRET` | `inbox-sync`, `octagon-mcp` (Microsoft Graph) |
| `RESEND_API_KEY`, `DIGEST_FROM`, `FEEDBACK_FROM`, `FEEDBACK_TO` | `digest-email`, `feedback` |

---

## Operating it

Full detail in the
[Operations Runbook](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Operations-Runbook).
Admins can check most of this from Claude with `/health`, `/tokens` and `/usage`.

```sql
-- is anything stale?
select public.sync_health();

-- do the scheduled jobs still exist?
select public.check_cron_manifest();

-- mint a token (hand the plaintext over once; only the hash is stored)
insert into mcp_tokens (token_hash, consultant_recruitcrm_id, label, can_write, is_admin, active)
values (encode(digest('<plaintext>','sha256'),'hex'), <recruitcrm_id>, 'Name (Recruiter)', true, false, true);
```

Revoke with `/tokens` (preview, then confirm). Leavers are revoked automatically when RecruitCRM
marks them inactive (0136).

Slack webhooks live in `app_settings`: `alert_webhook_url` (sync alerts only, the admin bot) and
`digest_webhook_url` (the briefs, #briefs). The queue and coach DMs use their apps' bot tokens.

---

## Key findings

Why the numbers are what they are. Fuller treatment in
[Data Caveats](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Data-Caveats).

1. **Funnel parity with RecruitCRM's own report is capped at about 0.4%, and the cause is theirs.**
   The residual is events the API returns and their report omits. The platform matches the API,
   which is reproducible.
2. **Call KPIs count tagged calls only, so they understate.** Most Devyce calls arrive untagged.
   `/tagcalls` suggests a category per call, and since 0148 reports show a "likely BD / client"
   count for untagged calls beside the tagged count, never added in.
3. **The spreadsheet is a validation reference, not a source of truth** ([D8](docs/DECISIONS.md)).
   Ratios match; pre-2026 absolute counts do not, because that activity was never logged.
4. **Supabase cannot serve HTML** (edge functions force `text/plain`), which is one reason the
   dashboard now lives in the connector's own widget.
5. **There is no "Internal Interview" stage.** It means 3rd Interview.
6. **The client/BD funnel lives in the company "Company Status" custom field.** Contacts are
   mirrored since 03/11/2026 (0145), without email or phone.
7. **RecruitCRM does emit delete events**; the platform subscribes to the four `*.deleted` events
   and still reconciles hourly in case one is missed.

---

## Status

At 04/11/2026. The dated detail, including what is open, is at the top of [ROADMAP.MD](ROADMAP.MD).

| Area | Status |
|---|---|
| Data model, sync, semantic layer (M0–M3) | Done; contacts mirrored since 03/11/2026 |
| Dashboard (M4) | Done; in the connector's `get_dashboard` widget since 20/10/2026 |
| Claude query and action layers (M5, M6) | Done: 80 tools, 26 prompts, 82 commands, live audited writes since 12/08/2026 |
| Slack layer | Briefs live; action queue live to a four-person pilot; Octagon Coach in shadow mode |
| Hardening (M7) | Partial: audit fixes 29/10–03/11/2026 shipped; no CI; items open in the roadmap |

**Related:** [Architecture](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Architecture) · [Operations Runbook](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Operations-Runbook) · [CONTRIBUTING.md](CONTRIBUTING.md) · [ROADMAP.MD](ROADMAP.MD)
