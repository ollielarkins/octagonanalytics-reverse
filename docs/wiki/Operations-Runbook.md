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

Twelve entities. Live ones warn at 10 minutes stale, critical at 30; `notes` at 45/180 (it runs
every 15 min); reconciles and the off-limit refresh at 26h and 50h. The watchdog runs every 5
minutes and the dashboard shows a red banner naming the failing feed.

## Tokens and access

`mcp_tokens` holds SHA-256 hashes — never the token itself. Per token: `consultant_recruitcrm_id`,
`can_write`, `is_admin`, `active`.

- `consultant_recruitcrm_id = 0` is the admin sentinel: no consultant record, so no personal desk.
- Revoke by setting `active = false`.
- OAuth sessions are rows labelled `oauth-session`, created by the token exchange, inheriting
  `can_write` and `is_admin` from the token that was pasted.

To grant write access, set `can_write = true`. To make someone an admin — whole-team visibility —
set `is_admin = true`.

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

**5. The connect page's script was destroyed by WordPress.** `wpautop` injects `</p> <p>` at blank
lines, including inside `<script>`, which broke both the feedback button and OAuth sign-in.
*Guard:* `scripts/check-connect-page.js`, and no blank lines in that file.

The common thread: nothing automated would have caught any of them. A smoke test asserting the
version endpoint and one real tool call would have caught the first two within seconds.

## Data hygiene backlog

| Item | Status |
|---|---|
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
