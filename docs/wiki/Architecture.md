# Architecture

```
RecruitCRM  ──►  recruitcrm-sync  ──►  Supabase (Postgres)  ──►  RPCs / views  ──►  octagon-mcp  ──►  Claude
 (system of      (edge function,        (the mirror)            (the metrics       (MCP server +
  record)         pg_cron)                                       layer)             widgets)
     ▲                                                                                    │
     └────────────────── writes, two-step, audited ──────────────────────────────────────┘
```

Reads come from the mirror. Writes go to RecruitCRM, then the affected records are refreshed
immediately so the mirror doesn't lag behind a change you just made.

## Components

| Component | What it is | Auth |
|---|---|---|
| `octagon-mcp` | Remote MCP server. Tools, prompts, and two inline widgets | Open — per-user Octagon tokens + OAuth 2.1 bridge |
| `recruitcrm-sync` | The mirror. Modes: backfill, incremental, reconcile, history | Locked — Supabase JWT |
| `recruitcrm-webhook` | Near-real-time change trigger from RecruitCRM | Open — external caller |
| `dashboard` / `dashboard-data` | Static dashboard page and its JSON | Open — public, no PII |
| `slack-command` | Slack entry point | Open — external caller |
| `recruitcrm-probe` / `recruitcrm-discover` | Read-only API shape probes. Temporary | Locked |

`verify_jwt` for every function is declared in `supabase/config.toml` so it travels with the repo
and can't be flipped by a stray CLI flag. Anything marked "open" authenticates its own callers.

## Sync

Page size 100, 100ms between pages.

| Job | Schedule |
|---|---|
| Incremental sync (all entities) | Every 2 minutes |
| History resync | Every minute |
| Sync health watchdog | Every 5 minutes |
| Reconcile — consultants | 03:00 daily |
| Reconcile — clients | 03:10 |
| Reconcile — jobs | 03:20 |
| Reconcile — deals | 03:30 |

**Nine entities are health-monitored**: candidates, clients, consultants, jobs, calls, deals, plus
the three nightly reconciles. Live entities warn at 10 minutes stale and go critical at 30;
reconciles warn at 26 hours, critical at 50. The dashboard shows a red banner and names the failing
feed rather than quietly serving stale figures.

## Data model

**Core:** `consultants`, `clients`, `jobs`, `candidates`, `deals` — UUID primary keys,
`recruitcrm_id` as the external key, `slug` where other payloads reference by slug.

**Events:** `candidate_stage_events` is the single source for the whole funnel. `call_activity`
holds Devyce telephony (metadata only — no phone numbers, no call notes). `audit_log` records every
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

## Widgets

Two inline MCP Apps widgets, self-contained HTML over postMessage with no external requests:

- **Dashboard** — branches on the viewer. Recruiters get their desk; admins get firm plus team.
- **Scorecard** — shared by `weekly_kpis` and `billing`, branching on payload shape.

## Repo layout

```
supabase/
  config.toml          verify_jwt per function
  functions/           edge functions
  migrations/          0000–0046, sequential, replayable
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
