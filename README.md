# Octagon Recruitment Analytics Platform

Live analytics on top of **RecruitCRM**, replacing manual spreadsheet reporting with an
always-current mirror of the firm's recruitment data — exposed as **dashboards** for viewing and
**Claude** as a direct interface that answers questions and performs audited write-back actions.

> **Guiding principle:** *trustworthy reads before writes.* Get the data model right → sync
> RecruitCRM into it reliably → define every metric once → show it and let Claude answer from it →
> then, carefully, let Claude act back into RecruitCRM.

> [!WARNING]
> **`dashboard-data` is unauthenticated and this repository is public.** It returns firm revenue,
> the full funnel and every consultant by name with their individual figures, to anyone with the
> URL. Open as of 15/09/2026 — see [Data exposure](#data-exposure).

| | |
|---|---|
| Connector | `octagon-mcp` **3.44.0** — 50 tools, 26 prompts |
| Commands | 57 slash commands, in [octagon-plugins](https://github.com/ollielarkins/octagon-plugins) |
| Migrations | 0000–0081 |
| Writes | Live — 44 in `audit_log`, first on 12/08/2026 |
| Tool calls logged | 495 |

**Documentation lives in the [wiki](https://github.com/ollielarkins/octagonanalytics-reverse/wiki).**
Start there. This README covers the repository and how to operate it.

| I want to… | Go to |
|---|---|
| Use the platform as a recruiter | [Wiki → Onboarding](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Onboarding) |
| Know what a number means | [Wiki → Metrics](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Metrics-and-Definitions) |
| Know where numbers are soft | [Wiki → Data Caveats](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Data-Caveats) |
| Deploy, backfill, mint a token | [Wiki → Runbook](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Operations-Runbook) |
| Understand the design decisions | [`docs/DECISIONS.md`](docs/DECISIONS.md) |

---

## How it fits together

```
   RecruitCRM  ──sync──▶  Supabase (Postgres mirror)  ──▶  Semantic layer (SQL views + RPCs)
  (system of              incremental every 15 min          one canonical definition
   record)                webhooks for near-live change      per metric
       ▲                  hourly page-walks for deletes            │
       │                                            ┌──────────────┴──────────────┐
       │                                            │                             │
       └────────── write-back ──────────────  Claude (MCP connector)         Dashboard
                   (preview→confirm→audit)     read + gated write          (JSON API + page)
```

- **RecruitCRM is the single source of truth** ([D8](docs/DECISIONS.md)). Supabase is a live
  mirror; everything downstream reads the mirror. Writes go **back to RecruitCRM**, never to the
  mirror — which then catches up via sync, plus an immediate write-through.
- **One semantic layer.** Dashboards and Claude read the *same* canonical views and functions, so
  their numbers cannot disagree.
- **Activity is credited to the actor** — whoever moved the stage — not reassigned when someone
  leaves. Roughly 16% of 2026 activity belongs to people who have since left, and it stays theirs.

## Live scale

| Entity | Rows |
|---|---|
| candidates | 52,158 |
| candidate_stage_events | 44,440 |
| notes | 100,271 |
| call_activity | 10,331 |
| jobs | 6,025 (142 open) |
| clients | 4,703 |
| deals | 1,642 |
| consultants | 22 |

**2026 is the reliable reporting window.** Hiring-stage logging before 2026 is sparse, so firm
figures default to a 2026-onward window. That is a data-entry reality in RecruitCRM, not a platform
limitation.

---

## Repository layout

```
supabase/
  migrations/           0000–0081 — schema, semantic layer, functions, cron
  functions/
    recruitcrm-sync/      the mirror: backfill | incremental | reconcile | history | notes | offlimit
    recruitcrm-webhook/   near-live change trigger; tombstones on *.deleted events
    octagon-mcp/          the MCP connector: 50 tools, 26 prompts, OAuth bridge
    dashboard-data/       JSON API behind web/dashboard.html
    slack-command/        Slack /dashboard entry point
    digest-email/         scheduled digests
    feedback/             issue capture from the connect page
    dashboard/            defunct — Supabase cannot serve HTML
    recruitcrm-probe/     throwaway API probe, locked and gutted
    recruitcrm-discover/  throwaway discovery probe, locked and gutted
web/dashboard.html      static page rendering dashboard-data
docs/
  wiki/                 SOURCE OF TRUTH for the published wiki — edit here, then sync
  DECISIONS.md          design-decision log
plugins/                pointer only; the 57 commands live in octagon-plugins
rollout/, scripts/      rollout material and repo checks
```

> [!IMPORTANT]
> `docs/wiki/` is the source for the GitHub wiki, which is a **separate git repository**. Editing a
> page in the GitHub UI does not update this repo, and pushing here does not update the wiki. They
> drifted for a month before anyone noticed. Sync deliberately:
> ```bash
> git clone https://github.com/ollielarkins/octagonanalytics-reverse.wiki.git /tmp/wiki
> cp docs/wiki/*.md /tmp/wiki/ && cd /tmp/wiki && git add -A && git commit && git push
> ```

---

## Supabase project

**Ref** `kzcmssldvtjnbwwunuwm` · region `eu-west-1` (GDPR — candidate PII stays in-region) ·
Postgres 17 · project name "Reporting for CRM"

| Function | `verify_jwt` | Purpose |
|---|---|---|
| `recruitcrm-sync` | true | The mirror. Modes: `backfill`, `incremental`, `reconcile`, `history_recent`, `notes_recent`, `offlimit`, `backfill_all` |
| `octagon-mcp` | false | Remote MCP server. Authenticates its own callers via `mcp_tokens` |
| `recruitcrm-webhook` | false | RecruitCRM POSTs on change. Verifies `?key=`; routes by record shape; tombstones on `*.deleted` |
| `dashboard-data` | false | **Unauthenticated JSON API.** See the warning above |
| `slack-command` | false | Slack `/dashboard`; verifies the signing secret |
| `digest-email`, `feedback` | mixed | Scheduled digests; connect-page issue capture |
| `dashboard`, `recruitcrm-probe`, `recruitcrm-discover`, `storage-upload` | — | Defunct or throwaway. Safe to delete |

`verify_jwt` is declared per function in `supabase/config.toml` so it travels with the repo and
can't be flipped by a stray CLI flag.

### Sync schedule

| When | Job |
|---|---|
| every 15 min | incremental sync, all entities |
| every 1 min | candidate stage history — the funnel's live feed |
| every 15 min | notes re-walk |
| hourly :40, draining every 3 min | candidates deletion pass (~520 pages, ~13 chunks) |
| hourly :05 / :12 / :18 | reconcile clients / jobs / deals |
| 03:00, 03:25 daily | reconcile consultants, off-limit refresh |
| every 5 min | sync health watchdog |
| every 10 min | **cron manifest watchdog** — are the jobs themselves still there? |

Plus **15 webhook subscriptions** for near-live change, including the four `*.deleted` events.

> [!NOTE]
> The cron manifest watchdog exists because on 10/09/2026 the cron entries were deleted from the
> database and nothing noticed for five days — the watchdog that would have reported it had been
> deleted too, and staleness cannot distinguish a job that failed from one that no longer exists.
> `cron_manifest` declares the expected 18; add new permanent jobs to it in the same migration.

### Authentication and write safety

Every tool call must present a valid token — `Authorization: Bearer`, `x-octagon-token`, or an
`auth_token` argument. Tokens map to a consultant via `mcp_tokens` and are stored **only as SHA-256
hashes**, so a lost token is reissued, never recovered. The acting identity is derived from the
token server-side and cannot be spoofed by a tool argument, which is what protects the audit trail.
`can_write` and `is_admin` are per token.

Every write is two-phase **preview → confirm**, with optimistic concurrency where a stage could move
under it, an `audit_log` insert recording who/what/before→after, and a write-through refresh so the
mirror is correct within seconds. `updated_by` carries the actor's RecruitCRM id, so the action is
attributed in RecruitCRM's own activity log. Deletion is irreversible and guarded twice; email
cannot be recalled and will not send to an opted-out recipient.

---

## Secrets

Set in Supabase, never in the repo. `.gitignore` excludes `.env`, `*.key` and `secrets/`.

| Secret | Used by |
|---|---|
| `RECRUIT_CRM_API_TOKEN` | `recruitcrm-sync`, `octagon-mcp` — account-level RecruitCRM API token |
| `WEBHOOK_SECRET` | `recruitcrm-webhook` — the `?key=` on every subscription callback |
| `SLACK_SIGNING_SECRET` | `slack-command` |

Connector access is by per-user token in `mcp_tokens`, not a server secret. The old
`OCTAGON_WRITE_KEY` shared gate was replaced in v3 and is unused.

---

## Data exposure

`GET /functions/v1/dashboard-data` requires no token, key or header, and returns firm Won revenue,
the funnel, the deal pipeline and every consultant by name with their figures. The URL appears in
this README, the wiki and `web/dashboard.html`, in a repository GitHub reports as public.

It stays open until the endpoint is authenticated or reduced to genuinely publishable fields.
`web/dashboard.html` is what currently depends on it being open, so check that first.

The repository itself is clean of credentials: no personal access tokens or service-role keys are
committed. The only credentials in tracked files are Supabase **anon** JWTs in cron definitions,
which are public by design.

---

## Operating it

Full detail in the
[Operations Runbook](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Operations-Runbook).
The essentials:

```bash
# type-check before deploying - always
node --experimental-strip-types --check supabase/functions/octagon-mcp/index.ts

# deploy with the CLI, never the MCP tool, and never pass --no-verify-jwt
npx supabase functions deploy octagon-mcp --project-ref kzcmssldvtjnbwwunuwm --use-api

# confirm which build is live
curl -s https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/octagon-mcp
```

```sql
-- is anything stale?
select public.sync_health();

-- do the scheduled jobs still exist?
select public.check_cron_manifest();

-- mint a token (plaintext returned once; only the hash is stored)
insert into mcp_tokens (token_hash, consultant_recruitcrm_id, label, can_write, is_admin, active)
values (encode(digest('<plaintext>','sha256'),'hex'), <recruitcrm_id>, 'Name (Recruiter)', true, false, true);

-- revoke
update mcp_tokens set active = false where label = '…';
```

Optional Slack webhooks live in `app_settings`: `alert_webhook_url` (sync alerts),
`admin_webhook_url` (daily digest), `standup_webhook_url` (weekday standup).

---

## Key findings

Why the numbers are what they are. Fuller treatment in
[Data Caveats](https://github.com/ollielarkins/octagonanalytics-reverse/wiki/Data-Caveats).

1. **Funnel parity with RecruitCRM's own report is capped at ~0.4%, and the cause is theirs.**
   Chased to row level across five periods: 34 of 50 stage-months exact, total variance 30 rows in
   7,935. The residual is an event the API returns and their report omits, with no distinguishing
   property. Decision: match the API, which is reproducible, and never fudge the last 0.4%.
2. **Call categorisation has collapsed from 26% to 9% since May**, while call volume nearly doubled.
   BD and client call KPIs count only categorised calls, so they now understate reality roughly ten
   to one. Behavioural, not technical — but the metric is barely worth reporting until it recovers.
3. **The spreadsheet is a validation reference, not a source of truth** ([D8](docs/DECISIONS.md)).
   Ratios match; absolute pre-2026 counts do not, because that activity was never logged in
   RecruitCRM.
4. **Supabase cannot serve HTML.** Edge functions and public storage force `text/plain` with a
   restrictive CSP, so the dashboard is a JSON API plus a separately hosted static page.
5. **Three hiring pipelines, and no "Internal Interview" stage.** The real set is Assigned, Applied,
   Shortlist, CV Sent, Interview Request, 1st/2nd/3rd Interview, Rejected-Client/Consultant,
   Offered, Placed. "Internal Interview" means 3rd Interview.
6. **The client/BD funnel lives in the company "Company Status" custom field**, not the contact
   pipeline — only 15 contacts exist. There is no "Lead" status.
7. **RecruitCRM does emit delete events.** Long assumed otherwise, on the evidence that no delete
   webhook had ever arrived. The real reason was that nobody had subscribed to one; the hourly
   page-walks were compensating for a missing subscription.

---

## Status

| Milestone | Status |
|---|---|
| M0 Foundations & access | ✅ Done |
| M1 Data model | ✅ Done |
| M2 Ingestion / sync | ✅ Done — plus webhooks, delete events and a cron manifest watchdog |
| M3 Semantic layer | ✅ Done |
| M4 Dashboards | ✅ Done |
| M5 Claude query layer | ✅ Done — 50 tools, 26 prompts, 57 commands, per-user auth |
| M6 Claude action layer | ✅ Done — live, 44 audited writes since 12/08/2026 |
| M7 Hardening & rollout | ⚠️ Partial — auth, monitoring and a full command test done; `dashboard-data` exposure open, no CI, throwaway functions still deployed |

**The honest headline is still adoption.** The platform is broad, tested and in use by a handful of
people. Four tokens are in circulation. That, not capability, is what limits its value.
