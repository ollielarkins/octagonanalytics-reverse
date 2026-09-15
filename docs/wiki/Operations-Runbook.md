# Operations runbook

Admin only. Everything here can break production.

## Deploying

```bash
export SUPABASE_ACCESS_TOKEN=sbp_...   # personal access token, revoke after
npx supabase functions deploy octagon-mcp --project-ref kzcmssldvtjnbwwunuwm --use-api
```

**Never pass `--no-verify-jwt`.** `supabase/config.toml` declares the correct setting for every
function; passing the flag overrides it and applies it to *every* function in the command. That is
how `recruitcrm-sync` — which holds the RecruitCRM API token — was left open for two minutes on
10/08/2026.

Before deploying:

```bash
node --experimental-strip-types --check supabase/functions/octagon-mcp/index.ts
```

After deploying, always confirm:

```bash
curl -s --retry 8 --retry-delay 3 --retry-all-errors \
  https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
# expect {"name":"octagon-analytics","version":"3.x.y",...}
```

A 502 immediately after deploy is a cold boot — retry before assuming failure.

Bump `SERVER.version` in `octagon-mcp/index.ts` on every deploy. It's the only way to confirm from
outside which build is live.

> **Do not use the Supabase MCP `deploy_edge_function` tool for `octagon-mcp`.** It takes file
> content as an inline parameter, and the file is 79KB. On 10/08/2026 that call was made with a
> placeholder string and took the connector down for nine minutes. The CLI reads from disk; use it.

## Migrations

Sequential, in `supabase/migrations/`. Apply via the Supabase MCP `apply_migration` tool or the CLI,
and **always write the same SQL to the numbered file** so a fresh replay reproduces the database.

Conventions: `create or replace` for functions, `if not exists` for columns and indexes, a comment
block at the top explaining *why* — including the evidence, if the change is correcting something.

## Backfills

Re-upserts every record for an entity. Needed whenever a new column is added, because the
incremental sync only touches changed records.

```bash
curl -X POST -H "Authorization: Bearer <anon key>" \
  "https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill&entity=deals&start_page=1&max_pages=20"
```

Entities: `clients`, `candidates`, `jobs`, `calls`, `deals`, `notes`. Read-only against RecruitCRM.

Other modes: `mode=history_recent` (candidate stage events for recently-changed candidates — this is
the funnel's live feed), `mode=notes_recent` (re-walks the newest note pages and records health),
`mode=offlimit` (refreshes do-not-approach flags).

**Only `notes_recent` and `history_recent` update the health clock.** A plain backfill deliberately
does not — otherwise manually backfilling an entity would mark a dead incremental feed as healthy,
which is exactly how the funnel sat frozen for six days on 10/08/2026.

Measured timings: deals 16 pages in 13s, jobs 60 pages in ~2 minutes. If it stops early it returns
`resume_next_page` — call again with that as `start_page`.

**Backfills apply current mapping code to every row at once.** If the mapping has a bug, a backfill
propagates it to the whole table in one go. Check a small entity first and verify the result before
running a large one.

## Health

```sql
select sync_health();
```

Thirteen entities. Live ones warn at **20** minutes stale, critical at 30; `history_recent` and
`notes` at 25/60; reconciles and the candidates pass at 2h/4h; the off-limit refresh at 26h/50h. The
watchdog runs every 5 minutes, alerts only on transitions, and re-alerts a still-critical feed once
every 6 hours rather than every cycle.

Live warn was 10 minutes until 15/09/2026, while the incremental sync runs every 15 — so four
entities warned for 5 minutes in every 15, permanently, with nothing wrong. A health panel that
cries wolf on a schedule teaches people to stop reading it.

### Do the jobs still exist?

```sql
select public.check_cron_manifest();
```

`sync_health` watches whether feeds *ran*. This watches whether the jobs that run them **exist**, are
active, and are on the cadence they were declared at — because staleness cannot tell a job that
failed from a job that was deleted. `cron_manifest` declares the expected 18; drift counts as
critical, and undeclared jobs are reported but never alerted.

This exists because on 10/09/2026 the cron entries vanished and nothing noticed for five days: the
watchdog that should have caught it had been deleted too. If you add a permanent job, add it to
`cron_manifest` in the same migration or the watchdog will correctly flag it as undeclared.

## Tokens and access

`mcp_tokens` holds SHA-256 hashes — never the token itself. Per token: `consultant_recruitcrm_id`,
`can_write`, `is_admin`, `active`.

- `consultant_recruitcrm_id = 0` is the admin sentinel: no consultant record, so no personal desk.
- Revoke by setting `active = false`.
- OAuth sessions are rows labelled `oauth-session`, created by the token exchange, inheriting
  `can_write` and `is_admin` from the token that was pasted.

To grant write access, set `can_write = true`. To make someone an admin — whole-team visibility —
set `is_admin = true`.

**Rotated 15/09/2026.** All 17 tokens then active were revoked and four minted: Ollie (admin),
Bhavesh Patel, Steve Bernat, Dale Barnett — all write-enabled, only Ollie an admin. Eight people lost
access in that sweep, including three of the top billers; reinstating anyone is a fresh mint, since
the plaintext of a revoked token is unrecoverable by design.

A fifth row usually appears shortly afterwards, labelled `oauth-session`. That is the claude.ai token
exchange creating a session row that inherits `can_write` and `is_admin` from the token pasted into
the connector. It is expected, not a leak — but it does mean revoking a person's token does not kill
a session already issued from it. Revoke both.

## Incidents — 10/08/2026

Five in one day, all self-inflicted, none caught by tooling. They're recorded because the lesson in
each is a missing guard rail.

**1. Connector down, nine minutes.** A deploy via the MCP tool sent `"PLACEHOLDER"` as the file
content. Every tool call returned 500. Fixed by redeploying from disk with the CLI.
*Guard:* deploy `octagon-mcp` with the CLI only.

**2. JWT verification silently disabled on `recruitcrm-sync`.** Two functions batched into one
command with `--no-verify-jwt`. The sync holds the RecruitCRM API token. Open for ~2 minutes; fixed
via the Management API.
*Guard:* `supabase/config.toml`, and never pass the flag.

**3. Orphaned jobs went from 2,410 to 4,092.** A backfill applied a client lookup that was silently
truncated to 1,000 rows by PostgREST. Fixed by paging the lookup and re-running — which then dropped
orphans to 9, revealing the "40% archived companies" story had been wrong for months.
*Guard:* the `allRows` helper. And note the bug only became visible *because* a backfill applied it
everywhere at once.

**4. The dashboard widget was a syntax error for several hours.** An apostrophe escaped as `'`
inside a TypeScript template literal becomes a bare quote in the emitted JS, killing the whole
widget script. It rendered as a permanent "Loading dashboard…".
*Guard:* `scripts/check-widgets.js` evaluates the template literal and parses the result.
*Postscript:* the deeper problem was never the syntax error. Hosts often never mount an advertised
`ui://` resource from a custom remote connector at all, so a perfect widget still showed nothing.
`get_dashboard` stopped advertising it in 3.40.1 and the plugin renders the dashboard instead.

**5. The connect page's script was destroyed by WordPress.** `wpautop` injects `</p> <p>` at blank
lines, including inside `<script>`, which broke both the feedback button and OAuth sign-in.
*Guard:* `scripts/check-connect-page.js`, and no blank lines in that file.

The common thread: nothing automated would have caught any of them. A smoke test asserting the
version endpoint and one real tool call would have caught the first two within seconds.

## Data hygiene backlog

| Item | Status |
|---|---|
| `dashboard-data` is unauthenticated on a public repo | **Open. Highest priority.** Exposes firm revenue and per-consultant figures to anyone with the URL |
| Three `octagongroup.co.uk` job subscriptions disappeared 15/09/2026 | Open. Ids 37785/37786/37788 vanished during a subscription change; cause not established. Restorable |
| `/myday` and `/dayplan` fail for admin tokens | Open. `my_day` scopes to the caller's desk and an admin has no consultant record |
| 64 ghost deals with null `recruitcrm_id` | Pending deletion. £0, none Won, inflate pipeline counts |
| 27 off-limit candidates not in the mirror | Flagged 61 of 88; the rest were never synced |
| No write has ever executed | `audit_log` empty across 14 write tools |
| Two deals with a mistyped fee percentage | Correct at source in RecruitCRM |
| `recruitcrm-probe` / `recruitcrm-discover` | Temporary, still deployed. Roadmap M7 cleanup |
| No test suite or CI | Open. Highest-value engineering work outstanding |
| Unbounded selects on `stage_lookup`, `consultants` | Safe at current row counts; should use `allRows` |

## Point-in-time recovery

Confirm whether PITR is enabled. `daily_activity` (1,839 rows) was dropped on 10/08/2026 and, if it
isn't, that data is unrecoverable. It was a partial, superseded copy — but the general point stands
for anything dropped in future.

---

**See also:** [Architecture](Architecture) for how the pieces fit · [Data Caveats](Data-Caveats) for known soft spots · [Metrics and Definitions](Metrics-and-Definitions) for what you might break
