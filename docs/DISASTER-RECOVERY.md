# Backups & Disaster Recovery

Status as of 25/09/2026. Part of ROADMAP Milestone 7 ("Resilience").

## Current state: there are no backups

| | |
|---|---|
| Supabase plan | **Free** (organisation "Octagon Group") |
| Managed backups | **None.** `supabase backups list` returns an empty list |
| Point-in-time recovery | Off |
| Database size | 264 MB of the free plan's 500 MB |
| Region | eu-west-1 (Ireland) |
| Restore ever tested | No |

If the project were deleted, corrupted by a bad migration, or lost to a platform incident today,
there is nothing to restore from. Most of the data can be re-pulled from RecruitCRM; some cannot
(below).

---

## What would be lost

### A. Rebuildable from RecruitCRM (hours, not lost)

RecruitCRM is the system of record. These tables are a mirror and the sync can refill them.

| Table | Rows | How it comes back | Rough time |
|---|---|---|---|
| `candidates` | 52,391 | `backfill_all` pass, 40 pages/chunk | ~40 min |
| `clients`, `jobs`, `deals`, `consultants`, `call_activity` | 4,750 / 6,038 / 1,657 / 22 / 11,954 | backfill mode per entity | minutes |
| `notes` | 100,600 | notes backfill | ~1 hour |
| `candidate_stage_events` | 44,920 | history walk, one API call per candidate at the rate limit | **most of a day** — the funnel, dashboards and weekly KPIs are wrong until it finishes |
| `sync_state` | 14 | recreated by the first run of each sync | — |
| `deal_stage_events` | 2,269 | **unknown** — legacy table (see DECISIONS D1); no current sync writes it | — |

### B. Configuration — not in RecruitCRM, must be re-entered by hand

| Table | Rows | Impact if lost |
|---|---|---|
| `mcp_tokens` | 30 (6 active) | every recruiter's connector stops; all tokens re-minted and redistributed |
| `weekly_targets`, `billing_targets` | 55 / 7 | weekly KPI and billing reports show no targets |
| `app_settings` | 5 | cron bearer and other settings; digests and scheduled calls fail |
| `closure_reasons`, `stage_lookup`, `reporting_exclusions` | 18 / 10 / 3 | seeded by migrations — recoverable **only if** the migrations are complete |
| `cron_manifest` + the cron jobs themselves | 18 | recreated by migrations, same caveat |

### C. History — lost permanently

`audit_log` (every write made through Claude), `closure_reason_log`, `sync_alerts`, `mcp_call_log`
(usage telemetry), `feedback`, `candidates_archive` (retired candidates, kept for reinstatement).
`webhook_events` and `oauth_codes` are transient and don't matter.

### Schema

Rebuilding from `supabase/migrations` **does not currently work**: `0053`–`0057` are live in
production but not in `main`. Until they are committed, a rebuild produces a different database.

---

## Recommendation

1. **Upgrade the organisation to a paid Supabase plan.** Paid plans include daily backups; point-in-time
   recovery is an add-on. This is the only option that also covers class C. It is a purchase, so
   it is Octagon's decision — check current pricing on supabase.com.
2. **Commit `0053`–`0057`** so the schema can be rebuilt from the repo. CI (`scripts/check-migrations.js`)
   already tracks the gap and will fail once the files land until `KNOWN_GAPS` is emptied.
3. **Until (1) is done, export classes B and C weekly.** They total well under 1 MB. **Not automated
   yet**, because the export contains token hashes and `app_settings` secrets and needs somewhere
   access-controlled to live — decide where first. Not the repo: it is public.
4. **Test a restore once**, into a separate project, and record how long it took here.

## Rebuild procedure (no backup available)

1. Create a new project in eu-west-1. Set function secrets (RecruitCRM token, service-role key,
   Resend, Slack).
2. Apply `supabase/migrations` in order. Confirm `select public.check_cron_manifest();` reports all
   jobs present.
3. Deploy every edge function with the CLI (see CONTRIBUTING.md). `config.toml` restores `verify_jwt`.
4. Run backfills: consultants → clients → jobs → deals → candidates (`backfill_all`) → calls → notes.
   The history walk queue then fills `candidate_stage_events` on its own; leave it running.
5. Re-enter class B: targets, `app_settings`, and re-mint every recruiter's token.
6. Point the claude.ai connector, the Slack command and the connect page at the new project URL.
7. Check `select public.sync_health();` is `ok` and spot-check the funnel against RecruitCRM.

Until step 4's history walk completes, tell recruiters funnel and KPI numbers are incomplete.
