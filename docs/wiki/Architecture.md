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
| `octagon-mcp` | Remote MCP server. 72 tools plus 26 prompts; returns data, not presentation | Open — per-user Octagon tokens + OAuth 2.1 bridge |
| `recruitcrm-sync` | The mirror. Modes: backfill, incremental, reconcile, history_recent, notes_recent, offlimit | Locked — Supabase JWT |
| `recruitcrm-webhook` | Near-real-time change trigger from RecruitCRM | Open — external caller |
| `feedback` | Issue/feedback box on the connect page | Open — validated, rate-limited |
| `dashboard` / `dashboard-data` | Static dashboard page and its JSON | **Open — genuinely unauthenticated. See the warning below** |
| `slack-command` | Slack entry point | Open — external caller |
| `daily-queue` | The 08:30 action queue DMs and the Monday manager exceptions DM, via the Team Briefs bot token | Locked — `pg_cron` presents `cron_bearer` |
| `slack-actions` | Slack interactivity: the queue's Done buttons. Opens a preview, writes the note to RecruitCRM as the consultant on Confirm | Open — verifies Slack's signature |
| `digest-email` | Renders the scheduled digests | Locked — `pg_cron` |
| `inbox-sync` | Polls connected Outlook inboxes via Microsoft Graph, metadata only | Locked — `pg_cron` |
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
| Candidates deletion pass — starts | 05:40 and 18:40 UTC |
| Candidates deletion pass — drains | Every 3 minutes |
| Reconcile — clients | Hourly at :05 |
| Reconcile — jobs | Hourly at :12 |
| Reconcile — deals | Hourly at :18 |
| Reconcile — consultants | 03:00 daily |
| Off-limit refresh | Hourly at :25 |
| Assignment sweep | Hourly at :40 |
| Meetings, this quarter and last | 06:10 daily |
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

## `dashboard-data` is unauthenticated

> [!WARNING]
> `GET /functions/v1/dashboard-data` returns firm Won revenue, the full funnel, the deal pipeline and
> **every consultant by name with their individual figures** — with no token, key or header.

The URL appears in `README.md` and this wiki, in a repo that is public on
GitHub. Anyone who finds it can read Octagon's revenue and every consultant's performance.

Still open as of 28/10/2026. It stays open until the endpoint is either authenticated or reduced to
fields that are genuinely safe to publish. `web/dashboard.html`, the static page that read it, was
removed on 28/10/2026; the remaining caller is `slack-command` (the Slack `/dashboard`).

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

Two inline MCP Apps widgets, defined in `supabase/functions/octagon-mcp/widgets.ts` and served by
`resources/read` with `_meta.ui` (empty CSP, `prefersBorder`):

- **Dashboard** (`ui://octagon/dashboard`, from `get_dashboard`) — branches on the viewer. Inline it
  is a summary card (recruiters: their desk; admins: firm figures) with an **Open dashboard** button;
  fullscreen is the full desk or firm-plus-team view.
- **Scorecard** (`ui://octagon/scorecard`, from `weekly_kpis` and `billing`) — branches on payload
  shape: one recruiter gets progress bars, managers and admins a team table.

Each widget is one self-contained HTML page: the MCP Apps SDK browser client inlined
(`ext_apps_bundle.ts`, regenerated by `scripts/build-ext-apps-bundle.js`), the Octagon theme kit
(Claude host style variables for structure, Octagon accents adjusted per theme), and a render
function. Nothing loads from outside. `scripts/check-widgets.js` parses the emitted pages.

History: `get_dashboard` stopped advertising its widget in **3.40.1** because the host so often
mounted nothing. The cause was the widgets' own hand-rolled postMessage handshake, which never
completed `ui/initialize` or reported a size. **3.63.0** moved both widgets onto the SDK and
**3.64.0** linked `get_dashboard` again (`DASHBOARD_WIDGET_LINKED` in `widgets.ts`), together with
octagon-dashboard 0.5.0, which stopped redrawing the bare dashboard with visualize. Scoped
dashboards are still drawn by that plugin from `structuredContent`.

`weekly_kpis` and `billing` still advertise `ui://octagon/scorecard` and still carry that risk.

## Repo layout

```
supabase/
  config.toml          verify_jwt per function
  functions/           edge functions
  migrations/          0000–0122, sequential, replayable
docs/
  DECISIONS.md         design decisions with status and rationale
  wiki/                these pages
rollout/               system instructions and templates
web/                   OAuth login handoff page
```

## Known engineering gaps

- **No test suite and no CI.** Every change is verified by hand.
- **Two throwaway probe functions still deployed** (`recruitcrm-probe`, `recruitcrm-discover`).
- **Two cron jobs are not in `cron_manifest`**: `weekly-usage-slack` and `recruitcrm-assignment-sweep`.
  The watchdog won't notice if either disappears.
- **Unbounded selects** remain on `stage_lookup` and `consultants`. Both are far under the 1,000-row
  cap so they're safe today, but they should use the `allRows` helper — an unbounded select on
  `clients` is what caused the 40% orphaned-jobs bug.

---

**See also:** [Operations Runbook](Operations-Runbook) for running and fixing it · [Data Caveats](Data-Caveats) for what the pipeline cannot tell you · [Metrics and Definitions](Metrics-and-Definitions) for the layer on top
