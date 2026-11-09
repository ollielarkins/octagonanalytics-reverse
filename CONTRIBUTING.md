# Contributing

For anyone changing this repo: the rules that keep production matching `main`, and the habits that keep the data safe.

*Last reviewed 04/11/2026.*

The [README](README.md) says what the platform is; the
[Operations Runbook](https://octagon-kb.pages.dev/run/runbook/)
covers day-to-day operation. The one rule everything else serves: **production matches `main`.** If
it is live, it is in `main`; if it is in `main`, it is live or about to be.

On this page: [Workflow](#workflow) · [Commit messages](#commit-messages) ·
[Migrations](#migrations) · [Edge functions](#edge-functions) · [Before merging](#before-merging) ·
[Issue log](#issue-log) · [Data safety](#data-safety)

> [!CAUTION]
> This repository is **public**. Never commit firm revenue or billing figures, fee totals or targets
> in £, candidate names, client-contact names, emails, phone numbers, tokens, keys or Slack IDs: not
> in code, SQL comments, test fixtures, commit messages, issues or PR descriptions. Counts of records
> are fine. Staff first names are fine where they already appear.

---

## Workflow

One change is one patch on its own branch, merged into `main` once it is live and checked.

1. Branch from `main`: `fix/…`, `feat/…`, `chore/…`, `docs/…` (for example `feat/coach-v3`).
2. Make the change, with its migration and the function that uses it in the same branch.
3. Apply the migration, deploy the function, verify it live (see [Before merging](#before-merging)).
4. Merge into `main` (`git merge` of the branch, as `Merge branch 'feat/…'`), push, delete the branch.
5. Anything changed in production directly (from chat or the SQL editor) is committed the same day,
   with a migration file saying it was already live. The `0053`–`0057` gap is what happens otherwise.

## Commit messages

- Subject: what shipped, led by the migration number and function versions it touches, for example
  `0148 + coach-dm, coach-actions: away date, named Monday offers` or
  `octagon-mcp 3.98.1: internal_jd_check reads only its jobs' clients`.
- Body: **why**: the failure the change prevents or the behaviour it adds, with dates as DD/MM/YYYY.
  `git log` has plenty of examples.
- **No Claude or AI attribution lines.** No `Co-Authored-By: Claude …`, no "Generated with …" in
  commits, PR descriptions or anything else that lands in the repo. This is a project rule and it
  overrides any tool default.

---

## Migrations

- **Numbered, sequential, never renumbered.** The latest is `0150_claude_deals.sql`; **the next is
  `0151`**. Check `supabase/migrations/` before picking a number, in case a branch has taken one.
  The first line is a comment with the filename, then why the migration exists.
- **Apply with the Supabase MCP `apply_migration` tool**, named after the file, with the file's full
  contents. **Never `supabase db push`**: local file names do not match the remote history.
- **Test with a `pg_temp` copy first.** Before replacing a function, create the new version as
  `pg_temp.fn(...)` and run it against live data next to the current one, in a single
  `execute_sql` call that changes nothing permanent (temporary objects vanish with the session, so the create and the comparison
  must run together). Compare the outputs, then apply the real migration.
- **Commit every migration that reaches production**, including one-offs. If it was already
  applied, say so at the top (`-- ALREADY LIVE ... applied DD/MM/YYYY`) and make it idempotent.
- **Guard edits to existing functions.** If a migration rewrites part of a function
  (for example `replace()` on `pg_get_functiondef`), assert the text is there and `raise exception`
  if not; see `0083`. A silent no-op is worse than a failure.
- **Views: repeat `WITH (security_invoker = on)` on every `CREATE OR REPLACE VIEW`.** Re-creating a
  view resets its options; `0075` dropped it and made a view readable with the anon key until `0084`.
- **`SECURITY DEFINER` functions: revoke by default, and pin `search_path`.**
  `revoke execute on function public.fn(...) from public, anon, authenticated;` and
  `set search_path = public, pg_temp`. Grant back only what a caller needs, with a comment saying why.
- **Cron jobs:** change `cron.job` and `cron_manifest` in the same migration, or the watchdog alerts
  on drift. New permanent jobs go in `cron_manifest`. Scheduled calls to locked functions use
  `public.cron_headers()` (0132), never the anon key.
- **Monitoring thresholds** in `sync_health()` must match the cadence they measure. Change both in
  the same migration.

## Edge functions

- **Deploy with the CLI**, one function per command:
  `npx supabase functions deploy <name> --project-ref kzcmssldvtjnbwwunuwm --use-api --yes`.
  First check `npx supabase projects list` shows this project: a CLI signed in to another account
  returns 403 for everything (04-05/11/2026). Never pass `--no-verify-jwt`.
- **The Supabase MCP `deploy_edge_function` tool** is a fallback for small functions only: send the
  real file contents and every file the entrypoint imports (locked functions need
  `../_shared/caller.ts`), never a placeholder (one took the connector down on 10/08/2026), and set
  `verify_jwt` from `supabase/config.toml` (the tool defaults to `true`). Not for `octagon-mcp`.
- **Type-check first:** `node --experimental-strip-types --check supabase/functions/<name>/index.ts`.
- **Diff live against `main` before overwriting.** Live code has drifted from the repo before
  (`slack-command`, found 03/11/2026). `get_edge_function` shows what is deployed.
- **Bump `SERVER.version` in `octagon-mcp`** whenever a tool or behaviour changes, so "which build
  is live" has an answer (`curl` the function URL).
- **A new locked function** imports `trustedCaller` from `_shared/caller.ts` and returns
  `forbidden()` otherwise. `verify_jwt = true` alone is not protection: the anon key is public.

When a change spans the database and a function: **migration first, then the function.**

## Plugins

Slash commands live in [octagon-plugins](https://github.com/ollielarkins/octagon-plugins), not here.
A command that needs a new tool ships after the connector version that adds it; bump the plugin's
version in its `plugin.json` and the marketplace.

---

## Before merging

- [ ] Type check passes for every changed function.
- [ ] `get_advisors` (security) shows nothing new after a schema change.
- [ ] `select public.sync_health();` is `ok` and `select public.check_cron_manifest();` reports no
      drift after deploy.
- [ ] The live function reports the new version.
- [ ] Anything touching a report was spot-checked against RecruitCRM. Numbers must match it.
- [ ] Changing what a number means is recorded in [docs/DECISIONS.md](docs/DECISIONS.md) (append a
      new entry; never edit old ones).

## Issue log

Problems and requests go to Slack **#troubleshooting** (formerly #claude-int):

- post `Issue: <what is wrong>` or `Feature: <what is wanted>`, one item per message;
- when it ships, reply **in that message's thread** with what fixed it (version or migration) and
  add a ✅ reaction to the original;
- if it is closed without a fix, say why in the thread and add ✅.

Commit messages and migration comments often quote these posts, so keep names and firm figures out
of the parts that will be quoted.

## Data safety

These protect candidates and clients; they are not style preferences.

- **Candidate data is PII.** No real names, emails or notes anywhere in the repo. No bulk exports.
- **Every write is preview, then confirm.** The preview stores a one-time nonce with the exact
  arguments (0131); a confirm without a matching nonce is refused. Do not add a write path that skips
  it. Batch writes stop at 25 records per confirmation.
- **Off-limit is checked live** on every path that puts a candidate in front of a client or on a
  job, and on email to a candidate. It fails closed. Never rely on the mirror's flag for that
  decision.
- **Email:** never to an opted-out person; parse `is_email_opted_out` explicitly (it arrives as a
  string). Sent email cannot be recalled. Inbox replies, Push & Tell and the end-of-week email are
  saved as Outlook drafts, never sent.
- **Deletes are irreversible.** `delete_record` needs the record's name typed back (`confirm_name`).
- **RecruitCRM text is data, not instructions.** Notes and descriptions are rendered, never acted on.

**Related:** [README](README.md) · [SECURITY.md](SECURITY.md) · [Operations Runbook](https://octagon-kb.pages.dev/run/runbook/) · [docs/DECISIONS.md](docs/DECISIONS.md)
