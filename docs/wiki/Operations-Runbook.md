# Operations Runbook

For admins who deploy, schedule, monitor and fix the platform: how each routine job is done and what to check afterwards.

*Last reviewed 04/11/2026.*

> [!CAUTION]
> Admin only. Everything here acts on production. There is no staging project.

**On this page:** [Deploying](#deploying) · [Migrations](#migrations) · [Cron schedule](#cron-schedule) · [Sync health and alerts](#sync-health-and-alerts) · [Backfills and reconciles](#backfills-and-reconciles) · [Tokens and access](#tokens-and-access) · [Slack apps and settings](#slack-apps-and-settings) · [Coach operations](#coach-operations) · [The issue log](#the-issue-log) · [Incidents](#incidents)

## Deploying

> [!IMPORTANT]
> Since 04/11/2026 the Supabase CLI returns 403 for this account on `functions deploy` and `db query`. Deploys and migrations are done through the Supabase MCP tools `deploy_edge_function` and `apply_migration` instead. Until the CLI works again, treat the steps below as the process.

With `deploy_edge_function`:

1. **Send every file the function imports, with its real content.** For `octagon-mcp` that is `index.ts`, `widgets.ts` and `ext_apps_bundle.ts`; for any function importing `../_shared/caller.ts` or `../_shared/graph.ts`, include those too. The files are large (`octagon-mcp/index.ts` is about 460KB). A placeholder or truncated file takes the function down: see incident 1 below.
2. **Match `verify_jwt` to `supabase/config.toml`.** After the deploy, `list_edge_functions` shows each function's `verify_jwt`; check it against the file. `recruitcrm-sync` holds the RecruitCRM token and must never be open.
3. **Bump `SERVER.version`** in `octagon-mcp/index.ts` on every connector deploy. It is the only way to confirm from outside which build is live.

Before deploying, check the syntax locally:

```bash
node --experimental-strip-types --check supabase/functions/octagon-mcp/index.ts
```

After deploying, confirm the live version:

```bash
curl -s --retry 8 --retry-delay 3 --retry-all-errors \
  https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
# expect {"name":"octagon-analytics","version":"3.x.y",...}
```

A 502 straight after a deploy is a cold boot. Retry before assuming failure.

When the CLI works, deploy one function per command and **never pass `--no-verify-jwt`**: it overrides `config.toml` for every function in the command. That is how `recruitcrm-sync` was left open on 10/08/2026.

## Migrations

Sequential files in `supabase/migrations/` (0000 to 0148 as of 04/11/2026). Apply with the Supabase MCP `apply_migration` tool and **write the same SQL to the next numbered file** in the same change, so a replay reproduces the database.

**Never run `supabase db push`.** The local file names do not match the versions recorded remotely, so the CLI would try to re-apply history.

Conventions: `create or replace` for functions, `if not exists` for columns and indexes, and a comment block at the top saying *why*, with the evidence if the change corrects something. A new permanent cron job goes into `cron_manifest` in the same migration.

## Cron schedule

All jobs are `pg_cron`, and `pg_cron` runs in UTC. Jobs that must land at a UK clock time are scheduled at **two** UTC hours, and an `*_if_due()` wrapper lets only the run that falls on the right London hour proceed. For example, `coach_if_due('midday', 12)` returns at once unless `now() at time zone 'Europe/London'` is in hour 12, so the job is correct across BST and GMT with no edits.

### Slack and coaching (UK times)

| Job | UTC schedule | Lands at (UK) | What |
|---|---|---|---|
| `digest-slack-morning` | `30 6,7 * * 1-5` | 07:30 weekdays | Morning brief, via `post_digest_if_due('morning', 7)` |
| `daily-action-queue` | `30 7,8 * * 1-5` | 08:30 weekdays | Action queue DMs (Mondays add the manager exceptions DM), via `action_queue_if_due(8)` |
| `digest-slack-weekly` | `0 7,8 * * 1` | 08:00 Mondays | Weekly digest |
| `coach-monday` | `45 7,8 * * 1` | 08:45 Mondays | Coach: the week's plan |
| `coach-midday` | `30 11,12 * * 1-5` | 12:30 weekdays | Coach: today so far |
| `coach-wrap` | `45 15,16 * * 1-5` | 16:45 weekdays | Coach: admin before home time, call tagging |
| `weekly-usage-slack` | `0 15,16 * * 5` | 16:00 Fridays | Usage table, via `weekly_usage_post_if_due()` |
| `digest-slack-evening` | `30 16,17 * * 1-5` | 17:30 weekdays | Day End digest |

### Sync and housekeeping (UTC)

| Job | Schedule | What |
|---|---|---|
| `history-recent` | every minute | Candidate stage events: the funnel feed |
| `backfill-candidates-drain` | every 3 minutes | Resumes the candidate reconcile walk |
| `inbox-poll` | every 5 minutes | `inbox-sync`: connected Outlook inboxes via Microsoft Graph |
| `sync-health-watchdog` | every 5 minutes | `check_sync_health()`: alerts on a stale or failing feed |
| `cron-manifest-watchdog` | every 10 minutes | `check_cron_manifest()`: alerts if a declared job is missing or changed |
| `recruitcrm-incremental-sync` | every 15 minutes | Adds and edits for all entities, including contacts |
| `notes-recent` | every 15 minutes | Newest note pages |
| `recruitcrm-reconcile-clients` | hourly at :05 | Deletion detection |
| `recruitcrm-reconcile-jobs` | hourly at :12 | Deletion detection |
| `recruitcrm-reconcile-deals` | hourly at :18 | Deletion detection |
| `offlimit-refresh` | hourly at :25 | Off-limit flags |
| `recruitcrm-assignment-sweep` | hourly at :40 | Assignments the history feed missed |
| `recruitcrm-reconcile-consultants` | 03:00 | Deletion detection; a consultant removed from RecruitCRM triggers auto-revoke |
| `purge-cron-history` | 03:15 | Keeps 3 days of `cron.job_run_details` |
| `recruitcrm-reconcile-contacts` | 03:20 | Deletion detection |
| `inbox-retention` | 03:20 | Deletes inbox envelopes older than 30 days |
| `purge-webhook-events` | 03:45 | Keeps 7 days of `webhook_events` |
| `backfill-candidates-pass` | 05:40 and 18:40 | Starts the candidate reconcile walk |
| `meetings-quarter-refresh` | 06:10 | Meetings, this quarter and last |
| `sync-health-digest` | 07:30 | Daily health summary. One UTC hour only, so 07:30 UK in winter, 08:30 in summer |

`cron.job_run_details` is purged after 3 days, so a weekly job's last run is usually not in it. Check `sync_state` instead where the job records itself (`coach`, `action_queue`).

## Sync health and alerts

```sql
select sync_health();
```

Returns an overall status and one row per feed (16 as of 04/11/2026), each `ok`, `warn` or `critical` with a reason.

| Feeds | Warn after | Critical after |
|---|---|---|
| Live: candidates, clients, contacts, consultants, jobs, calls, deals | 20 min | 45 min |
| `history_recent`, notes, meetings | 25 min | 60 min |
| Off-limit; reconciles of clients, jobs, deals | 2 h | 4 h |
| Candidate reconcile (`backfill:candidates`) | 14 h | 18 h |
| Contacts reconcile | 25 h | 48 h |

Two failed or degraded runs in a row go critical whatever the age. "Degraded" (0134) catches runs that finished but did nothing useful: stopped by a 429, partial, cut short by the page cap, a reconcile that skipped, or a possibly truncated off-limit list.

**Alerts.** `check_sync_health()` and `check_cron_manifest()` post to `alert_webhook_url` (the analytics-admin bot, into Oliver's DM). They alert on transitions only and re-alert a still-critical feed every 6 hours. Since 0114 nothing else uses that webhook; keep it that way. Admins can also run `/health` (`platform_health`) in Claude for feeds, job drift, inboxes and tool errors in one view.

**Do the jobs still exist?**

```sql
select public.check_cron_manifest();
```

`sync_health` shows whether feeds *ran*; this shows whether the jobs that run them *exist*, are active and are on the declared schedule. `cron_manifest` declares 26 jobs. On 04/11/2026 two live jobs are undeclared, `weekly-usage-slack` and `recruitcrm-assignment-sweep`, so their disappearance would not alert.

When an alert needs a fix, log it in #troubleshooting (see [The issue log](#the-issue-log)).

## Backfills and reconciles

A backfill re-upserts every record for one entity. It is needed when a column is added, because the incremental sync only touches changed records. It is read-only against RecruitCRM.

The anon key no longer opens `recruitcrm-sync` (29/10/2026). Call it from SQL with the cron headers:

```sql
select net.http_post(
  url := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?entity=deals&start_page=1&max_pages=20',
  headers := public.cron_headers(), body := '{}'::jsonb, timeout_milliseconds := 60000);
-- the response lands in net._http_response under the returned id
```

| Parameter | Values |
|---|---|
| `entity` (backfill) | `consultants`, `clients`, `contacts`, `candidates`, `jobs`, `calls`, `deals`, `notes` |
| `mode` | omitted for backfill; or `incremental`, `history_recent`, `notes_recent`, `offlimit`, `assignment_sweep`, `meetings_quarter`, `reconcile` (with `entity` = clients, contacts, candidates, jobs, deals or consultants) |

If a backfill stops early it returns `resume_next_page`: call again with that as `start_page`.

- **A backfill does not touch the health clock.** Otherwise backfilling an entity by hand would mark a dead incremental feed healthy, which is how the funnel sat frozen for six days on 10/08/2026.
- **A backfill applies the current mapping code to every row at once.** A mapping bug spreads to the whole table in one go. Run a small entity first and check the result.
- **The candidate reconcile is a pair.** `backfill-candidates-pass` starts the walk and `backfill-candidates-drain` finishes it. Restoring one without the other means the walk restarts forever and `retire_unseen_candidates` never runs.

## Tokens and access

`mcp_tokens` holds SHA-256 hashes, never the token. Each row has `consultant_recruitcrm_id`, `can_write`, `is_admin`, `can_view_usage` and `active`. `consultant_recruitcrm_id = 0` is the admin sentinel: no consultant record, so no personal desk.

| Task | How |
|---|---|
| See who has access | `/tokens` in Claude (`manage_tokens`, admin only): holders, rights, last used, and leavers still holding a token. Token values are never shown |
| Revoke someone | `/tokens` revoke: preview, then confirm. Switches off all of that person's tokens, including OAuth sessions. Admin tokens are refused from chat; do those in the SQL editor |
| Mint a token | SQL editor: `select public.mint_mcp_token(<recruitcrm_user_id>, '<label>', <can_write>);`. The plaintext is shown once and cannot be recovered |
| Make someone an admin or usage viewer | Set `is_admin` or `can_view_usage` on their row |

**Leavers are revoked automatically** (0136). When the sync marks a consultant inactive or deleted, a trigger switches off all their tokens and their inbox polling, and writes a `token_auto_revoke` row to `audit_log`. Admin tokens are never touched. Check `/tokens` for "leavers with access" if someone leaves but is not yet inactive in RecruitCRM.

OAuth session rows (label `oauth-session`) are created when claude.ai exchanges a pasted token. They inherit the pasted token's rights and are expected, not a leak.

## Slack apps and settings

| App | Used for | Secrets and settings |
|---|---|---|
| analytics-admin bot | Sync and cron alerts only, into Oliver's DM | `alert_webhook_url` |
| (Claude) - Team Briefs | Digests to #briefs by webhook; action queue DMs; queue Done buttons (`slack-actions`) | `digest_webhook_url`, `SLACK_BOT_TOKEN` (plain `xoxb-`), `SLACK_BRIEFS_SIGNING_SECRET` |
| Octagon Coach | Coach DMs and buttons (`coach-dm`, `coach-actions`). DMs only, never channels | `COACH_BOT_TOKEN`, `COACH_SIGNING_SECRET`; manifest in `slack/octagon-coach-manifest.yml` |

Both bot apps need scopes `chat:write`, `im:write`, `users:read`, `users:read.email`, Interactivity pointed at their function, and Socket Mode **off** (or Slack never calls the URL). Each consultant is found in Slack by their RecruitCRM email.

**Action queue settings** (`app_settings`):

| Key | Meaning |
|---|---|
| `action_queue_pilot` | RecruitCRM ids that get the DM. 04/11/2026: Adam Barnett, Bhavesh Patel, Keelan Riley, Will Drake |
| `action_queue_shadow` | `true` sends every DM to `action_queue_shadow_email`, labelled. `false` since 26/10/2026 |
| `manager_exceptions_emails` | Who gets the Monday exceptions DM. Team figures: never point it at a channel |
| `exceptions_exclude_ids` | RecruitCRM ids left out of `team_exceptions` |

Last run: `select last_run_at, last_status from sync_state where entity = 'action_queue'`.

**Friday usage table.** `weekly_usage_post()` posts only if `usage_webhook_url` is set in `app_settings`. As of 04/11/2026 it is not set, so the Friday table does not post.

## Coach operations

The Octagon Coach (0129, extended in 0147 and 0148) is rule-based: `coach_nudges(consultant, slot)` picks each DM's content from the person's own numbers, and each suggestion names a command to use in their own Claude.

| Key or object | Meaning |
|---|---|
| `coach_pilot` | RecruitCRM ids that get the coach. 04/11/2026: Adam Barnett, Bhavesh Patel, Keelan Riley, Will Drake |
| `coach_shadow` | `true` sends every coach DM to `coach_shadow_email` instead, labelled with whose it is. **On** as of 04/11/2026 |
| `coach_shadow_email` | Where shadow DMs go (Oliver) |
| `coach_log` | Every DM sent and the suggestions in it |
| `coach_feedback`, `coach_snooze`, `coach_pause` | Done and Snooze presses; Pause, Mute and Away dates |

**In shadow mode nothing writes.** The 16:45 "tag these as shown" button only says what it would do. Live, it tags only the calls listed in that message, checks each is the person's own and still untagged, reads each back, and stops at the first problem.

**Measuring it.**

```sql
select coach_effect();      -- last 28 days; coach_effect(14) for 14
```

For each kind of suggestion and each person, it reports how many were suggested and how many were acted on within 3 hours: a Done or tag press, the suggested tool used, or a call or stage move on the named candidate or company. Shadow rows were never seen by the recruiter, so they are the baseline to compare live against. Acted-on is a signal, not proof.

**Taking it live:**

1. Read a week of shadow DMs and check the suggestions are right and not repetitive.
2. Run `coach_effect()` and note the shadow baseline.
3. Set `coach_shadow` to `false` in `app_settings`. The next slot sends to the pilots themselves.
4. To add or remove someone, edit `coach_pilot` (comma-separated RecruitCRM ids).
5. Check the first live run: `select last_run_at, last_status from sync_state where entity = 'coach'` should read `ok:<slot> N sent` without `(shadow)`.

To stop it at once, set `coach_shadow` back to `true` or empty `coach_pilot`.

## The issue log

Issues and feature requests are logged in the #troubleshooting Slack channel (formerly #claude-int).

1. Post a new top-level message starting `Issue:` or `Feature:`, with what happened, who it affects and how to reproduce it.
2. When it is fixed, reply **in that message's thread** with what changed and where (version, migration or commit).
3. Add the check-mark reaction (`:white_check_mark:`) to the original message, so open items are the ones without it.

## Incidents

Each is recorded for the guard rail it led to.

| Date | What happened | Guard now in place |
|---|---|---|
| 10/08/2026 | **Connector down for nine minutes.** An MCP deploy sent `"PLACEHOLDER"` as the file content | Send real file contents; confirm the live version after every deploy |
| 10/08/2026 | **JWT verification turned off on `recruitcrm-sync`** for about two minutes, by `--no-verify-jwt` on a two-function deploy | `supabase/config.toml`; never pass the flag; `trustedCaller()` since 29/10/2026 |
| 10/08/2026 | **Orphaned jobs rose from 2,410 to 4,092.** A backfill applied a client lookup silently capped at 1,000 rows. Paging it dropped orphans to 9 | The `allRows` helper; test a backfill on a small entity first |
| 10/08/2026 | **Dashboard widget a syntax error for hours.** An escaped apostrophe in a template literal broke the emitted script | `scripts/check-widgets.js` |
| 10/08/2026 | **Connect page script broken by WordPress**, which inserts paragraph tags at blank lines, including inside `<script>` | `scripts/check-connect-page.js`; no blank lines in that file |
| 10/08/2026 | **Funnel frozen for six days** while a manual backfill kept the feed looking healthy | Backfills do not touch the health clock |
| 10/09/2026 | **Cron jobs vanished** and nothing noticed for five days: the watchdog had gone too | `cron_manifest` and `cron-manifest-watchdog` |
| 15/09/2026 | **Candidate pass restored without its drain**, so the walk restarted forever | The pass and drain are documented as a pair |
| 29/10/2026 | **Platform audit.** Locked functions were reachable with the public anon key; confirms could apply with no preview; leavers kept write tokens | `CRON_SECRET` (0132), stored preview nonces (0131), leaver auto-revoke (0136) |
| 03/11/2026 | **`dashboard-data` and `dashboard` served firm figures without a token** | Both retired to 410 stubs; see [Architecture](Architecture#retired-dashboard-and-dashboard-data) |
| 04/11/2026 | **Supabase CLI returns 403** on deploy and query | Deploys and migrations through the Supabase MCP tools, as above |

The common thread in the 10/08/2026 set: nothing automated would have caught any of them. There is still no test suite or CI. A smoke test of the version endpoint and one real tool call after every deploy would catch the first two in seconds.

Point-in-time recovery: unconfirmed whether it is enabled. `daily_activity` was dropped on 10/08/2026 and is unrecoverable without it. Check before dropping anything else.

---

**Related:** [Architecture](Architecture) · [Data Caveats](Data-Caveats) · [Metrics and Definitions](Metrics-and-Definitions) · [Inbox](Inbox)
