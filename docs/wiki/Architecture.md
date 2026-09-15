# Architecture

```
RecruitCRM  ──►  recruitcrm-sync  ──►  Supabase (Postgres)  ──►  RPCs / views  ──►  octagon-mcp  ──►  Claude
 (system of      (edge function,        (the mirror)            (the metrics       (MCP server +
  record)         pg_cron)                                       layer)             prompts)
     ▲                                                                                    │
     └────────────────── writes, two-step, audited ──────────────────────────────────────┘
```

Reads come from the mirror. Writes go to RecruitCRM, then the affected records are refreshed
immediately so the mirror doesn't lag behind a change you just made.

## Components

| Component | What it is | Auth |
|---|---|---|
| `octagon-mcp` | Remote MCP server. 50 tools plus 26 prompts; returns data, not presentation | Open — per-user Octagon tokens + OAuth 2.1 bridge |
| `recruitcrm-sync` | The mirror. Modes: backfill, incremental, reconcile, history_recent, notes_recent, offlimit | Locked — Supabase JWT |
| `recruitcrm-webhook` | Near-real-time change trigger from RecruitCRM | Open — external caller |
| `feedback` | Issue/feedback box on the connect page | Open — validated, rate-limited |
| `dashboard` / `dashboard-data` | Static dashboard page and its JSON | **Open — genuinely unauthenticated. See the warning below** |
| `slack-command` | Slack entry point | Open — external caller |
| `recruitcrm-probe` / `recruitcrm-discover` | Read-only API shape probes. Temporary | Locked |

`verify_jwt` for every function is declared in `supabase/config.toml` so it travels with the repo
and can't be flipped by a stray CLI flag. Anything marked "open" authenticates its own callers.

## Sync

Page size 100, 100ms between pages.

| Job | Schedule |
|---|---|
| Incremental sync (all entities) | Every 15 minutes |
| Candidate stage history (recent) | Every minute |
| Notes (re-walk newest pages) | Every 15 minutes |
| Candidates deletion pass — starts | Hourly at :40 |
| Candidates deletion pass — drains | Every 3 minutes |
| Reconcile — clients | Hourly at :05 |
| Reconcile — jobs | Hourly at :12 |
| Reconcile — deals | Hourly at :18 |
| Reconcile — consultants | 03:00 daily |
| Off-limit refresh | 03:25 daily |
| Sync health watchdog | Every 5 minutes |
| Cron manifest watchdog | Every 10 minutes |

The reconciles are staggered at :05, :12 and :18 so they never contend with each other or with the
candidates pass on the half hour. They are full page-walks — 47 pages for clients, 61 for jobs, 16
for deals, ~520 for candidates — because that is the only way to detect a deletion by polling.

The candidates pass and its drain are a **pair**: the pass (`start_page=1`) resets the cursor and
begins a walk, the drain resumes it across the ~13 chunks a full pass needs. Neither works alone.
Restoring one without the other, as happened on 15/09/2026, means the pass restarts forever and
never completes, so `retire_unseen_candidates` never runs at all.

## Webhooks

RecruitCRM pushes changes to `recruitcrm-webhook`. 15 subscriptions are registered, including
`candidate.deleted`, `job.deleted`, `company.deleted`, `deal.deleted`,
`candidate.hiringstage.updated`, `deal.stage.updated` and `job.status.updated`.

Three things are worth knowing:

1. **RecruitCRM never names the event in the body.** Every payload is a full record with no
   `event`/`type` field. Since we choose the `target_url` per subscription, the name rides on the URL
   (`?event=job.deleted`) and the handler reads it from there.
2. **Routing is by record shape, not keywords.** The original router keyword-scanned the whole body
   in a fixed order, and a job payload contains `note_for_candidates`, so it matched the candidate
   rule first — 68 job and 16 company payloads were routed to "candidates" and spent refreshing the
   wrong entity. It now trusts the event name, falling back to distinctive top-level keys.
3. **Deletions are handled, not synced.** The incremental sync only walks records that still exist,
   so firing it for a delete does nothing at all. The row is tombstoned directly instead.

Webhooks are the fast path; the polling sync stays as the guarantee. Deliveries get missed, and the
poll is what makes the mirror converge anyway.

> ### `dashboard-data` is unauthenticated
>
> `GET /functions/v1/dashboard-data` returns firm Won revenue, the full funnel, the deal pipeline and
> **every consultant by name with their individual figures** — with no token, key or header. The URL
> appears in `README.md`, this wiki and `web/dashboard.html`, in a repo that is public on GitHub.
> Treat this as an open exposure until it is either authenticated or reduced to fields that are
> genuinely safe to publish.

**Twelve entities are health-monitored**: candidates, clients, consultants, jobs, calls, deals, plus
the three nightly reconciles. Live entities warn at 10 minutes stale and go critical at 30;
reconciles warn at 26 hours, critical at 50. The dashboard shows a red banner and names the failing
feed rather than quietly serving stale figures.

## Data model

**Core:** `consultants`, `clients`, `jobs`, `candidates`, `deals` — UUID primary keys,
`recruitcrm_id` as the external key, `slug` where other payloads reference by slug.

**Events:** `candidate_stage_events` is the single source for the whole funnel. `call_activity`
holds Devyce telephony (metadata only — no phone numbers, no call notes). `notes` mirrors RecruitCRM
notes, which is what makes leads and internal interviews countable. `audit_log` records every
write.

**Identity:** `consultants.recruitcrm_id` is canonical. Name columns are display-only.
`stage_lookup` maps RecruitCRM's integer stage IDs to `(stage_metric, stage_name)`.

`daily_activity` was removed on 10/08/2026 — never connected to a source, superseded by
`candidate_stage_events` and `call_activity`, and half its columns were never populated.

## The metrics layer

Every figure comes from a view or an RPC — `dashboard_json`, `funnel_report`, `client_report`,
`kpis_report`, `billing_report`, `my_day`, `rejection_report`, `fee_analysis` and the rest. Nothing
queries base tables ad hoc. That's what guarantees the dashboards and Claude can't disagree.

All are `security definer`, granted to `service_role` only.

## Identity and access

Tokens live hashed in `mcp_tokens`, mapped to a consultant, with `can_write` and `is_admin` per
token. Identity is derived server-side from the bearer token on every call and can never be set by
a tool argument.

claude.ai requires OAuth, so there's a bridge: you paste your Octagon token into a hosted login
page, it's validated against `mcp_tokens`, and an OAuth access token is issued that maps to the same
consultant with the same `can_write` and `is_admin`. claude.ai gets OAuth; we keep per-user
identity.

## Rendering

The connector returns data; the client renders it. `get_dashboard` hands back `structuredContent`
and a text summary, and the octagon-analytics plugin draws the dashboard from that JSON.

Two inline MCP Apps widgets exist — self-contained HTML over postMessage, no external requests — and
their HTML is still served by `resources/read`:

- **Dashboard** — branches on the viewer. Recruiters get their desk; admins get firm plus team.
- **Scorecard** — shared by `weekly_kpis` and `billing`, branching on payload shape.

`get_dashboard` stopped advertising the dashboard widget in **3.40.1**. Hosts frequently never
complete the fetch-and-mount for a custom remote connector (claude-ai-mcp#471), so the recruiter got
nothing at all; the plugin path is reliable and the advertisement only added a failure mode. The HTML
remains reachable by URI for any host that asks.

`weekly_kpis` and `billing` still advertise `ui://octagon/scorecard` and still carry that risk.

## Repo layout

```
supabase/
  config.toml          verify_jwt per function
  functions/           edge functions
  migrations/          0000–0052, sequential, replayable
docs/
  DECISIONS.md         design decisions with status and rationale
  wiki/                these pages
rollout/               system instructions and templates
web/                   OAuth login handoff page
```

## Known engineering gaps

- **No test suite and no CI.** Every change is verified by hand.
- **Two throwaway probe functions still deployed** (`recruitcrm-probe`, `recruitcrm-discover`).
- **Unbounded selects** remain on `stage_lookup` and `consultants`. Both are far under the 1,000-row
  cap so they're safe today, but they should use the `allRows` helper — an unbounded select on
  `clients` is what caused the 40% orphaned-jobs bug.
