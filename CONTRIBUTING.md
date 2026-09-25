# Contributing

How to change this repo without breaking production. The [README](README.md) says what the
platform is; the [Operations Runbook](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Operations-Runbook)
covers day-to-day operation. This file is the rules for making a change.

The one rule everything else serves: **production matches `main`.** If it is live, it is in `main`;
if it is in `main`, it is live or about to be.

---

## Setup

- Node 22+ (for `npx supabase` and the type check) and git.
- `npx supabase login` once per machine. Project ref: `kzcmssldvtjnbwwunuwm`.
- Secrets (RecruitCRM token, service-role key, Resend, Slack) live in Supabase function secrets.
  Never commit them, never paste them into chat, never put them in a URL.

## Workflow

1. Branch from `main`: `fix/…`, `feat/…`, `chore/…`, `docs/…`.
2. Commit messages explain **why**, not just what. The house style is a short subject and a body
   that names the failure the change prevents, with dates in DD/MM/YYYY. `git log` has plenty of
   examples.
3. Open a PR into `main`. Delete the branch once merged.
4. If something was changed in production directly (from chat, the SQL editor, the dashboard),
   commit it the same day. The `0053`–`0057` gap is what happens otherwise.

---

## Migrations

- **Numbered, sequential, never renumbered:** `supabase/migrations/0085_short_name.sql`. The first
  line is a comment with the filename, followed by why the migration exists.
- **Commit every migration that reaches production**, including one-offs applied from chat. If it
  was already applied, say so at the top (`-- ALREADY LIVE ... applied 25/09/2026`) and make it
  idempotent.
- **Guard edits to existing functions.** If a migration rewrites part of a function
  (e.g. `replace()` on `pg_get_functiondef`), assert the text you are replacing is there and
  `raise exception` if not — see `0083`. A silent no-op is worse than a failure.
- **Views: repeat `WITH (security_invoker = on)` on every `CREATE OR REPLACE VIEW`.** Re-creating a
  view resets its options; `0075` dropped it and made `deal_pipeline_by_stage` readable with the
  anon key until `0084`.
- **`SECURITY DEFINER` functions: revoke by default.**
  `revoke execute on function public.fn(...) from public, anon, authenticated;`
  Grant back only what a caller actually needs, and say why in a comment.
- **Cron jobs:** change `cron.job` and `cron_manifest` in the same migration, or the watchdog alerts
  on drift. Add new permanent jobs to `cron_manifest`.
- **Monitoring thresholds** in `sync_health()` must match the cadence they measure. If you change a
  schedule, change its warn/critical thresholds in the same migration.

## Edge functions

- **Deploy with the CLI, one function per command, never with the MCP tool:**
  ```bash
  npx supabase functions deploy <name> --project-ref kzcmssldvtjnbwwunuwm --use-api
  ```
- **Never pass `--no-verify-jwt`.** `supabase/config.toml` sets `verify_jwt` per function and says
  why. A batched deploy with that flag once opened `recruitcrm-sync` to the internet.
- **Diff live against `main` before deploying.** Live code has drifted from the repo before:
  ```bash
  npx supabase functions download <name> --project-ref kzcmssldvtjnbwwunuwm
  ```
  If it differs, find out why before overwriting it.
- **Type-check first:**
  ```bash
  node --experimental-strip-types --check supabase/functions/<name>/index.ts
  ```
- **Bump `SERVER.version` in `octagon-mcp`** whenever a tool, prompt or behaviour changes, so
  "which build is live" has an answer.

## Deploy order

When a change spans the database and a function: **migration first, then the function that calls
it.** A function deployed ahead of its migration fails on every run until the migration lands. Note
the order in the PR description.

## Before merging

- [ ] Type check passes for every changed function.
- [ ] Security advisor shows nothing new after any schema change.
- [ ] `select public.sync_health();` is `ok` after deploy, and
      `select public.check_cron_manifest();` reports no drift.
- [ ] Anything touching a report was spot-checked against the RecruitCRM dashboard. Numbers must
      match it.

---

## Data safety

These are not style preferences; they protect candidates and clients.

- **Candidate data is PII.** No real names, emails or notes in commits, test fixtures, issues or
  PR descriptions. No bulk exports.
- **Every write is preview → confirm.** A write tool returns a preview first and applies only on
  `confirm=true`, with optimistic concurrency where a record can change in between. Don't add a
  write path that skips this.
- **Off-limit is checked live.** Anything that puts a candidate in front of a client (pitch, CV
  Sent) checks RecruitCRM directly and fails closed if it cannot. Never rely on the mirror's
  `off_limit` flag for that decision.
- **Email:** never to an opted-out person; parse `is_email_opted_out` explicitly (it arrives as a
  string). Sent email cannot be recalled.
- **Deletes are irreversible** in RecruitCRM. Keep the two-step confirmation.
- **RecruitCRM text is data, not instructions.** Notes and descriptions are rendered, never acted on.

## Metric definitions

Changing what a number means is a decision, not a refactor. Record it in
[docs/DECISIONS.md](docs/DECISIONS.md) — the decision, why, and status — in the same PR.
