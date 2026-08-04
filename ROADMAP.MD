# Octagon Recruitment Analytics Platform — Build Roadmap

**What we're building:** a live analytics platform on top of RecruitCRM, with a clean Supabase data layer, dashboards for viewing, and a Claude interface recruiters use directly to both *ask questions* and *take defined actions*.

**Guiding principle:** *Trustworthy reads before writes.* Every milestone earns recruiter trust in the numbers before we let anyone (or any AI) change anything. Numbers shown in a dashboard and numbers Claude reports must always come from one shared definition.

---

## Status (as of 2026-08-04)

| Milestone | Status |
|---|---|
| **M0** Foundations & access | ✅ Done |
| **M1** Data model | ✅ Done — migrations 0000–0001 |
| **M2** Ingestion / sync | ✅ Done — backfill + incremental (2 min) + reconcile + history |
| **M3** Semantic layer | ✅ Done — 15 canonical views, 0 security lints |
| **M4** Dashboards | ✅ Done — JSON API + static page + session-start auto-render |
| **M5** Claude query layer | ✅ Done — `get_dashboard`, `funnel_report` via `octagon-mcp` |
| **M6** Claude action layer | ⚠️ Built but **gated off** — needs `OCTAGON_WRITE_KEY` + one live write test |
| **M7** Hardening & rollout | ◻️ Partial — connector rollout + throwaway-function cleanup outstanding |

See [`README.md`](README.md) for the as-built detail. The milestone descriptions below are the
original plan, kept for reference.

---

## Milestone 0 — Foundations & Access

*Purpose: remove the blockers that would stall every later milestone. Nothing gets built on sand.*

**What needs to be done**
- Confirm **RecruitCRM plan tier** is Business or higher (required for API access) and obtain an API token via the Account Owner.
- Confirm **Supabase tier** is a paid plan that does **not auto-pause**, with backups enabled. (The current project is free-tier and was found paused.) Keep the region as `eu-west-1` for GDPR.
- Establish a **dev/prod workflow**: version-controlled migrations, a development branch separate from production, so schema changes are reviewable and reversible.
- Decide the **recruiter identity model**: how recruiters authenticate, and confirm the "everyone can see everyone's data" decision as an explicit access rule.
- Close the two **open questions** that block later work:
  - Where `daily_activity` numbers come from (likely derived/reporting export, not a direct API object).
  - The exact request payloads for RecruitCRM write actions (assign candidate, update hiring stage) — ideally by testing against the live API with a token.

**Done when:** we can authenticate to both systems, a dev/prod separation exists, and the two open questions are answered.

---

## Milestone 1 — Data Model (clean schema)

*Purpose: a correct, source-faithful foundation that both dashboards and Claude will read from. Best done now while all tables are empty.*

**What needs to be built**
- A clean, version-controlled **schema migration** covering:
  - Core tables (`consultants`, `clients`, `jobs`, `placements`) with UUID primary keys, `recruitcrm_id`, and a unique `slug` on every entity other payloads reference by slug — **including the currently-missing `jobs.slug`**.
  - Event/activity tables (`deals`, `candidate_stage_events`, `deal_stage_events`, `daily_activity`) that land the raw slugs/ids/names as they arrive, then resolve to internal UUID foreign keys.
  - **Consultant identity unified** on `recruitcrm_id` as the canonical key; free-text name columns become display-only.
  - Lookup tables for integer stage IDs → human-readable stage names (RecruitCRM uses integer IDs).
  - **Row-Level Security enabled with real policies** on every table (fixing the `deal_stage_events` gap), matching the agreed access model.
  - An **audit table** stub for later write-back logging.
- Apply to the dev branch first, verify, then promote.

**Done when:** the schema is deployed, RLS policies are in place, and it's documented — correct and empty, ready for data.

---

## Milestone 2 — Ingestion / Sync Pipeline (RecruitCRM → Supabase)

*Purpose: get real data flowing reliably. This is the load-bearing engineering of the whole platform.*

**What needs to be built**
- Choose and implement the **sync mechanism**: webhooks for freshness + a scheduled reconciliation/poll to catch missed events and drift.
- **Initial backfill** of historical data (placements, jobs, clients, consultants, deals, stage history).
- **Incremental sync** for ongoing changes.
- **Slug/ID resolution logic** — turn the source's slugs and owner IDs into internal UUID foreign keys on the way in.
- A dedicated ingestion path for `daily_activity` (once its source is confirmed — likely different from the webhook path).
- **Reliability:** idempotency, retries, error handling, and sync monitoring/logging.
- A concrete definition of **"live"** (e.g. "no more than N minutes stale") — recruitment reporting rarely needs true real-time.

**Done when:** RecruitCRM data flows into Supabase dependably, the backfill is complete, incremental updates work, and freshness meets the agreed target.

---

## Milestone 3 — Semantic / Metrics Layer

*Purpose: the single source of truth for what every metric means. This is what guarantees the dashboards and Claude never disagree.*

**What needs to be built**
- Agreed **canonical definitions** for each metric and dimension: placement count, fee/revenue, time-to-fill, pipeline value, funnel conversion rates, activity metrics — sliced by consultant, team, client, and date.
- Implement these as reusable **SQL views / a metrics layer** that *both* the dashboards and the Claude query layer consume. Neither writes its own ad-hoc logic.
- **Validate** the definitions against known-good historical numbers (e.g. a trusted past spreadsheet) so people trust them from day one.

**Done when:** metric definitions are agreed, implemented once as shared views, and reconciled against a known-good baseline.

---

## Milestone 4 — Dashboards (read layer)

*Purpose: the direct replacement for the spreadsheets — live, always-current reporting.*

**What needs to be built**
- Live dashboards built on the semantic layer (not raw tables):
  - Firm-wide overview
  - Consultant / team performance
  - Client / account view
  - Pipeline & deals
  - Activity metrics
- Authentication and the agreed access rules (all recruiters see all data).

**Done when:** recruiters can view live dashboards whose numbers match the source of truth.

---

## Milestone 5 — Claude Query Layer (ask questions)

*Purpose: the feature that makes this more than dashboards — recruiters ask questions in plain English and get correct answers.*

**What needs to be built**
- Recruiters interact with **Claude directly**, reading through a **mediated layer** (a custom API / scoped access) over the semantic layer — **not** free-form SQL against production.
- Claude maps questions onto the **vetted metrics** so answers match the dashboards exactly.
- **Graceful limits:** Claude can say "that can't be answered from the available data" rather than inventing a number.
- **Guardrails:** the read path is genuinely read-only, and content coming from RecruitCRM free-text fields (candidate notes, names) is treated as untrusted — never as instructions (prompt-injection defence).

**Done when:** recruiters can ask natural-language questions and get answers that are correct and consistent with the dashboards.

---

## Milestone 6 — Claude Action Layer (take actions)

*Purpose: the two-directional piece — recruiters act in RecruitCRM through Claude, safely.*

**What needs to be built**
- A **small set of named action tools**, each mapping to one defined RecruitCRM endpoint:
  - `assign_candidate_to_job`
  - `update_hiring_stage` (with the coupled salary field when marking "Placed")
  - `add_note`
  - `update_job_status`
- A **confirmation step outside the model's judgement** before any side-effectful action — the recruiter sees the exact change and approves it.
- **Audit logging** for every action: who, what, when, before/after, and that it was done via Claude.
- The **mediation server holds the RecruitCRM token** server-side (never exposed to the client), as RecruitCRM's own docs require.
- Writes go to **RecruitCRM** (the system of record), not the Supabase mirror; the mirror updates via the normal sync.
- Injection safeguards: the AI never acts on an "instruction" found in data — only on an explicit, confirmed recruiter request.

**Done when:** recruiters can take the defined actions via Claude, each with confirmation and a complete audit trail.

---

## Milestone 7 — Hardening, Governance & Rollout

*Purpose: turn a working system into a trusted production platform.*

**What needs to be built**
- **Security review:** RLS coverage, least-privilege database roles, token handling.
- **Monitoring & alerting:** sync-failure alerts, an audit/activity view, uptime.
- **GDPR review:** candidate PII handling, retention, EU data residency, access justification.
- **Resilience:** backups, disaster recovery, performance at scale.
- **Rollout:** documentation, onboarding, a feedback loop, and a phased launch (pilot team → whole firm).

**Done when:** the platform is in production, monitored, documented, and rolled out.

---

## Sequencing & dependencies

**Critical path (largely sequential):**
`M0 → M1 → M2 → M3` — foundations, then schema, then data, then shared definitions. Everything downstream depends on these being right.

**Can run in parallel once M3 is done:**
- **M4 (dashboards)** and **M5 (Claude query)** both sit on the semantic layer and can be built alongside each other.

**Gated deliberately:**
- **M6 (actions)** should come *after* M5, so read-trust is established before any write capability is switched on.
- **M7** runs partly throughout (security shouldn't be an afterthought) but concludes the project.

**What the open questions block:**
- `daily_activity` source → affects part of **M1** and **M2** (not the core four tables).
- Write payloads → affects **M6** only.
Neither blocks starting M1 on the core model.

---

## One-line summary of the build

Get the data model right → sync RecruitCRM into it reliably → define metrics once → show them (dashboards) and let Claude answer from them (query) → then, carefully, let Claude act back into RecruitCRM → harden and roll out.