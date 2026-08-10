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
---

# Unused RecruitCRM API surface

*Added 10/08/2026, from the official OpenAPI spec (Recruit CRM API v8.7.6). The spec defines
**189 operations across 144 paths**. The platform currently uses **15**. This section is the
complete inventory of the other **174**, so that "can we do X?" stops being a research task.*

**The single most important finding: three of the four metrics we have been telling people are
"not tracked anywhere" have first-class RecruitCRM APIs.** The
[Data Caveats](docs/wiki/Data-Caveats.md) page, the org instructions and several months of
reporting all say leads, pitched candidates, internal interviews and client visits cannot be
reported. That was wrong for at least two of them, and probably three.

---

## Tier 1 — closes a known gap in what we report

### Pitched candidates — a complete feature we didn't know existed

`POST /v1/pitch/{candidate}/contact/{contact}` pitches a candidate to a contact. There is a pitch
*pipeline* with its own stages (`GET /v1/pitch-pipeline`), stage updates
(`POST /v1/pitch/{candidate}/updated-stage/{contact}`), and full history by candidate, by contact
and by pair. `GET /v1/pitch/{entity}/pitch-stage/{entitySlug}` lists where a candidate has been
pitched.

This is exactly the spec-pitch workflow Octagon already does by hand, and it is the "pitched
candidates" KPI the business asked for. If recruiters log pitches in RecruitCRM, we can report the
whole funnel — pitched → engaged → placed — with no new tables.

**Worth doing first.** It converts an "untracked" metric into a measured one and it has a
BD-reporting payoff.

### Client visits — meetings

`GET/POST /v1/meetings`, `/v1/meetings/search`, and `GET /v1/meeting-types`. If a client visit is
logged as a meeting of the right type, the fourth untracked KPI is a sync away — the same shape as
the Devyce call-activity work in migration 0027.

### Leads — contact stages

`GET /v1/sales-pipeline` returns Contact Stages. We concluded there was no "Lead" concept because
the *company* status custom field has no Lead value. The contact-level sales pipeline is a
different mechanism and may carry it. Needs a look before we keep saying leads are untrackable.

### Targets — a report we are reimplementing by hand

`GET /v1/target-report/get`. We built `weekly_targets`, `billing_targets`, `kpis_report()` and
`billing_report()` ourselves. RecruitCRM has a target report of its own. At minimum, worth
comparing against, in case the firm's real targets already live there and ours are a parallel
truth — exactly the failure mode decision D1 exists to prevent.

---

## Tier 2 — fills real holes in the current product

### Reference data: we are guessing at IDs we could simply look up

`GET /v1/currencies`, `/v1/industries`, `/v1/qualifications`, `/v1/languages`, `/v1/proficiencies`,
`/v1/salary-types`, `/v1/custom-call-types`, `/v1/note-types`, `/v1/task-types`, `/v1/teams`,
`/v1/off-limit-status`.

Concrete cost of not having these: `create_job` needs `currency_id`, and rather than looking it up
we infer it from the client's most recent job and fall back to `1`. Thermoteknix turned out to be
**19**, so the fallback would have created jobs in the wrong currency. `GET /v1/currencies` removes
the guess entirely. `custom-call-types` would let the Devyce BD/client-call mapping be driven by the
real list instead of three hardcoded label strings.

### Search endpoints — better lookup than ILIKE over the mirror

`/v1/candidates/search`, `/v1/companies/search`, `/v1/jobs/search`, `/v1/deals/search`,
`/v1/notes/search`, `/v1/tasks/search`, `/v1/meetings/search`, `/v1/invoices/search`,
`/v1/users/search`, `/v1/call-logs/search`, `/v1/hotlists/search`. Also
`GET /v1/jobs/{job}/assigned-candidates`, which is what `job_pipeline` reconstructs from the event
stream.

### Deals — we read them but cannot write them

`POST /v1/deals` and `POST /v1/deals/{deal}`. Billing is Won deal value, so "move this deal to Won
and enter the value" is *the* revenue-recording action at Octagon and Claude cannot do it. Given
billing is the number everyone cares about, this is arguably the highest-value write after jobs.
`GET /v1/deals-pipeline` gives the stage list.

### Placements — richer than we assumed

We concluded the placement record carries no money, which is true of its top-level fields. But
`GET /v1/custom-fields/placements` exists, as do `/v1/placements/search` and
`POST /v1/placements/{placement}`. Worth re-checking whether Octagon's fee data lives in placement
*custom* fields before treating D4 as settled.

### Tasks

`GET/POST /v1/tasks`. `daily_activity` had a `tasks_added` column that was actually populated
(2,060 in 2025, 824 in 2026) before that table was dropped. Tasks are real, they are in the API,
and they are a genuine activity signal we currently ignore.

---

## Tier 3 — new capability, not currently part of the product

- **Invoicing** (`/v1/invoices`, `/v1/invoice-status`, `/v1/invoice-templates`) — a finance layer
  we have never touched. Would connect placements to actual cash rather than deal value.
- **Timesheets** (`/v1/timesheets`) — only relevant if Octagon does contract placements; the deal
  custom fields include Start date and End date, which suggests some do.
- **Hotlists** (`/v1/hotlists`) — shared talent pools. A natural home for `match_candidates`
  output: "shortlist these five" could write a hotlist instead of ending in chat.
- **Email and sequences** (`/v1/emails`, `/v1/drafts`, `/v1/email-sequences/search`,
  `/v1/email/opt-out/status`) — we generate outreach copy but cannot send or track it. Note the
  opt-out endpoints: any sending feature must respect them.
- **Enrollments and subscriptions** — candidate/contact nurture sequences.
- **Files** (`POST /v1/files`, `GET /v1/files/{entity}/{slug}`) — CVs and job specs.
- **Resume parser** (`POST /v1/candidates/resume-parser`) — paste a CV, get a structured candidate.
  Pairs naturally with the existing `candidate_intake` prompt.
- **Candidate record depth** — work history, education history, off-limit status, question and
  answers. `off-limit` in particular is a compliance feature we are blind to: we could be
  reporting on or pitching candidates who are marked off-limit.

---

## Deliberately not planned

**Destructive operations.** `DELETE` exists for jobs, candidates, companies, contacts, deals,
notes, tasks, meetings, invoices, placements, call logs and hotlists. None of these should be
exposed through Claude. The system's whole safety story is preview → confirm → audit on a small set
of additive actions; a delete tool is a different risk class and RecruitCRM's own UI already has
one.

**Bulk mark-off-limit / mark-as-available.** Same reasoning — bulk state changes across records
are not something to drive from a chat interface.

---

## Sequencing

1. **Pitch** — closes a stated business gap, read-only first (history and stages), then the write.
2. **`GET /v1/currencies` and the other reference lists** — small, removes existing guesswork,
   makes `create_job` correct rather than inferred.
3. **Deal write** — makes the billing number actionable instead of only observable.
4. **Meetings and sales-pipeline** — settle whether client visits and leads are trackable, and
   correct the documentation either way.
5. Everything else on demand.

Before any of it: no write has yet succeeded through this platform. `audit_log` is empty. The
first successful `update_job` matters more than any item on this list, because every write tool
above inherits the same untested path.

---

## Appendix — complete inventory of unused operations

_174 unused operations of 189 total. Generated from the OpenAPI spec (Recruit CRM API v8.7.6), not hand-listed._

#### Pitch — the pitched-candidates metric (7)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/pitch-pipeline` | Get Pitch stages |
| GET | `/v1/pitch/pitch-candidate-history/{candidate}` | Pitch History of a Candidate |
| GET | `/v1/pitch/pitch-contact-history/{contact}` | Pitch History of a Contact |
| POST | `/v1/pitch/{candidate}/contact/{contact}` | Pitch candidate to contact |
| GET | `/v1/pitch/{candidate}/history/{contact}` | Pitch History of a Candidate and Contact |
| POST | `/v1/pitch/{candidate}/updated-stage/{contact}` | Update Pitch stage |
| GET | `/v1/pitch/{entity}/pitch-stage/{entitySlug}` | Get contacts where the candidate is pitched |

#### Meetings — the client-visits metric (7)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/meeting-types` | Get Meeting Types |
| GET | `/v1/meetings` | Show all meetings |
| POST | `/v1/meetings` | Creates a new meeting |
| GET | `/v1/meetings/search` | Search for meetings |
| DELETE | `/v1/meetings/{meeting}` | Delete a meeting |
| GET | `/v1/meetings/{meeting}` | Find meeting by ID |
| POST | `/v1/meetings/{meeting}` | Edit meeting |

#### Tasks (7)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/task-types` | Get Task Types |
| GET | `/v1/tasks` | Show all tasks |
| POST | `/v1/tasks` | Creates a new task |
| GET | `/v1/tasks/search` | Search for tasks |
| DELETE | `/v1/tasks/{task}` | Delete a task |
| GET | `/v1/tasks/{task}` | Find task by ID |
| POST | `/v1/tasks/{task}` | Edit task |

#### Invoicing and timesheets (18)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/custom-fields/invoices` | Show all Invoice Custom Fields |
| GET | `/v1/internal-custom-fields/invoices` | Show all Invoice Internal Custom Fields |
| GET | `/v1/invoice-status` | Get Invoice Status |
| GET | `/v1/invoice-templates` | Get Invoice Templates |
| GET | `/v1/invoices` | Show all invoices |
| POST | `/v1/invoices` | Creates a new invoice |
| GET | `/v1/invoices/search` | Search for invoices |
| DELETE | `/v1/invoices/{id}` | Delete an invoice |
| GET | `/v1/invoices/{id}` | Find invoice by ID |
| POST | `/v1/invoices/{id}` | Edit an invoice |
| POST | `/v1/invoices/{id}/status` | Update Invoice status |
| GET | `/v1/timesheets` | Get All Timesheets |
| POST | `/v1/timesheets` | Create Timesheet |
| POST | `/v1/timesheets/enable` | Enable Timesheet Settings |
| GET | `/v1/timesheets/rule-template` | Get Rule Template |
| GET | `/v1/timesheets/settings` | Get Timesheet Settings |
| POST | `/v1/timesheets/submit` | Submit Timesheet |
| GET | `/v1/timesheets/{timesheet}` | Get Timesheet Details |

#### Targets (1)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/target-report/get` | Get Target Report |

#### Hotlists (talent pools) (8)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/hotlists` | Show all Hotlists |
| POST | `/v1/hotlists` | Creates a new Hotlist |
| GET | `/v1/hotlists/search` | Search for hotlists |
| DELETE | `/v1/hotlists/{hotlist}` | Delete a hotlist |
| GET | `/v1/hotlists/{hotlist}` | Find hotlist by ID |
| POST | `/v1/hotlists/{hotlist}` | Edit a hotlist |
| POST | `/v1/hotlists/{hotlist}/add-record` | Add records to Hotlist |
| POST | `/v1/hotlists/{hotlist}/remove-record` | Remove records from Hotlist |

#### Email, drafts and sequences (7)

| Method | Path | What it does |
|---|---|---|
| POST | `/v1/drafts` | Create Email Draft |
| GET | `/v1/drafts/status/{draft_status_id}` | Draft Email Status |
| GET | `/v1/email-sequences/search` | Search for Sequences |
| POST | `/v1/email/opt-out/status` | Update Opted out status |
| GET | `/v1/email/opted-out` | Opted out entities |
| POST | `/v1/emails` | Send an Email |
| GET | `/v1/emails/status/{email_status_id}` | Sent Email Status |

#### Enrollments and subscriptions (7)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/enrollment-statuses` | Get All Enrollment Statuses |
| GET | `/v1/enrollments/search` | Search for Enrollments |
| GET | `/v1/subscriptions` | Show all subscriptions |
| POST | `/v1/subscriptions` | Creates a new subscription |
| DELETE | `/v1/subscriptions/{subscription}` | Delete a subscription |
| GET | `/v1/subscriptions/{subscription}` | Find subscription by ID |
| POST | `/v1/subscriptions/{subscription}` | Edit a subscription |

#### Candidate record depth (34)

| Method | Path | What it does |
|---|---|---|
| POST | `/v1/candidates` | Creates a new candidate |
| GET | `/v1/candidates/associated-field/{candidate}/{job}` | Get Job Associated Fields |
| POST | `/v1/candidates/associated-field/{candidate}/{job}` | Update Job Associated Fields |
| POST | `/v1/candidates/education-history/create` | Add Education History |
| DELETE | `/v1/candidates/education-history/{educationId}` | Delete a candidate Education History |
| POST | `/v1/candidates/education-history/{educationId}` | Edit Education History |
| POST | `/v1/candidates/mark-as-available` | Mark Candidate as Available |
| POST | `/v1/candidates/mark-off-limit` | Mark Candidate as Off Limit |
| GET | `/v1/candidates/off-limit` | Get List of candidates which are marked as off limit |
| GET | `/v1/candidates/profile-update-request-form` | Get Profile Update Request Form |
| GET | `/v1/candidates/question-and-answers/{candidate}` | Question And Answers of Candidate |
| POST | `/v1/candidates/question-and-answers/{candidate}` | Update Candidate Answers for the Questions |
| GET | `/v1/candidates/question-and-answers/{candidate}/{job}` | Question And Answers of Candidate for Job |
| POST | `/v1/candidates/question-and-answers/{candidate}/{job}` | Update Candidate Answers for the Questions for a Job |
| POST | `/v1/candidates/resume-parser` | Resume Parser |
| GET | `/v1/candidates/search` | Search for candidates |
| POST | `/v1/candidates/work-history/create` | Add Work Experience |
| DELETE | `/v1/candidates/work-history/{workId}` | Delete a candidate work experience |
| POST | `/v1/candidates/work-history/{workId}` | Edit Work Experience |
| DELETE | `/v1/candidates/{candidate}` | Delete a candidate |
| GET | `/v1/candidates/{candidate}` | Find candidate by slug |
| POST | `/v1/candidates/{candidate}` | Edit a candidate |
| POST | `/v1/candidates/{candidate}/apply` | Apply to Job |
| GET | `/v1/candidates/{candidate}/education-history` | Candidate Education History |
| POST | `/v1/candidates/{candidate}/enroll` | Enroll Candidate |
| GET | `/v1/candidates/{candidate}/hiring-stages` | Hiring Stages of Candidate |
| GET | `/v1/candidates/{candidate}/hiring-stages/{job}` | Hiring Stage of Candidate for Job |
| GET | `/v1/candidates/{candidate}/off-limit-history` | Off Limit History for Candidate |
| GET | `/v1/candidates/{candidate}/request-update` | Request Updated Profile |
| POST | `/v1/candidates/{candidate}/un-enroll` | Unenroll Candidate |
| POST | `/v1/candidates/{candidate}/unassign` | Un-assign Candidate |
| POST | `/v1/candidates/{candidate}/visibility/{job}` | Update Candidate Visibility in a Job |
| GET | `/v1/candidates/{candidate}/work-history` | Candidate Work Experience |
| GET | `/v1/custom-fields/candidates` | Show all Candidate Custom Fields |

#### Company and contact records (22)

| Method | Path | What it does |
|---|---|---|
| POST | `/v1/companies` | Creates a new company |
| POST | `/v1/companies/mark-as-available` | Mark Companies as Available |
| POST | `/v1/companies/mark-off-limit` | Mark Companies as Off Limit |
| GET | `/v1/companies/off-limit` | Get List of Companies which are marked as off limit |
| GET | `/v1/companies/search` | Search for companies |
| DELETE | `/v1/companies/{company}` | Delete a company |
| GET | `/v1/companies/{company}` | Find company by slug |
| POST | `/v1/companies/{company}` | Edit a company |
| GET | `/v1/companies/{company}/off-limit-history` | Off Limit History for Company |
| GET | `/v1/contacts` | Show all contacts |
| POST | `/v1/contacts` | Creates a new contact |
| POST | `/v1/contacts/mark-as-available` | Mark Contacts as Available |
| POST | `/v1/contacts/mark-off-limit` | Mark Contacts as Off Limit |
| GET | `/v1/contacts/off-limit` | Get List of Contacts which are marked as off limit |
| DELETE | `/v1/contacts/{contact}` | Delete a contact |
| GET | `/v1/contacts/{contact}` | Find contact by slug |
| POST | `/v1/contacts/{contact}` | Edit a contact |
| POST | `/v1/contacts/{contact}/enroll` | Enroll Contact |
| GET | `/v1/contacts/{contact}/off-limit-history` | Off Limit History for Contact |
| POST | `/v1/contacts/{contact}/un-enroll` | Unenroll Contact |
| GET | `/v1/custom-fields/companies` | Show all Company Custom Fields |
| GET | `/v1/custom-fields/contacts` | Show all Contact Custom Fields |

#### Deals (7)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/custom-fields/deals` | Show all Deal Custom Fields |
| POST | `/v1/deals` | Creates a new Deal |
| GET | `/v1/deals-pipeline` | Get Deals Stages |
| GET | `/v1/deals/search` | Search for deals |
| DELETE | `/v1/deals/{deal}` | Delete a deal |
| GET | `/v1/deals/{deal}` | Find deal by slug |
| POST | `/v1/deals/{deal}` | Edit a deal |

#### Placements (5)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/custom-fields/placements` | Show all Placement Associated Custom Fields |
| GET | `/v1/placements/search` | Search Placements |
| DELETE | `/v1/placements/{placement}` | Delete a placement |
| GET | `/v1/placements/{placement}` | Find placement by ID |
| POST | `/v1/placements/{placement}` | Edit a placement |

#### Jobs (remaining) (10)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/custom-fields/jobs` | Show all Job Custom Fields |
| GET | `/v1/jobs-pipeline` | Get Job Stages |
| GET | `/v1/jobs/application-form` | Get Job Application Form |
| GET | `/v1/jobs/application-form-metadata` | Get job application form metadata |
| GET | `/v1/jobs/compliance-terms` | Get compliance terms |
| GET | `/v1/jobs/list-xml-jobboards` | Get XML Job-Boards List |
| GET | `/v1/jobs/search` | Search for jobs |
| DELETE | `/v1/jobs/{job}` | Delete a Job |
| GET | `/v1/jobs/{job}/assigned-candidates` | Assigned candidates for job |
| GET | `/v1/jobs/{job}/stage-history/{candidate}` | Stage History of Candidate for job |

#### Call logs (remaining) (7)

| Method | Path | What it does |
|---|---|---|
| POST | `/v1/call-logs` | Creates a new Call Log |
| GET | `/v1/call-logs/get-recording-status/{call_log}` | Get Call Recording Upload Status |
| GET | `/v1/call-logs/search` | Search for call logs |
| POST | `/v1/call-logs/upload-call-recording` | Upload Call Recordings |
| DELETE | `/v1/call-logs/{call_log}` | Delete a call log |
| GET | `/v1/call-logs/{call_log}` | Find call log by ID |
| POST | `/v1/call-logs/{call_log}` | Edit a call log |

#### Notes (remaining) (6)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/note-types` | Get Note Types |
| GET | `/v1/notes` | Show all Notes |
| GET | `/v1/notes/search` | Search for notes |
| DELETE | `/v1/notes/{note}` | Delete a note |
| GET | `/v1/notes/{note}` | Find note by ID |
| POST | `/v1/notes/{note}` | Edit a note |

#### Pipeline and stage definitions (4)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/hiring-pipeline` | Get Candidate Stages |
| GET | `/v1/hiring-pipelines` | Get Multiple Hiring Pipelines |
| GET | `/v1/hiring-pipelines/{id}` | Get Hiring Pipeline Stages For A Pipeline |
| GET | `/v1/sales-pipeline` | Get Contact Stages |

#### Reference data for decoding IDs (10)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/collaborators` | Get Collaborators |
| GET | `/v1/currencies` | Get Currencies |
| GET | `/v1/custom-call-types` | Get Call Types |
| GET | `/v1/industries` | Get Industries |
| GET | `/v1/languages` | Get Languages |
| GET | `/v1/off-limit-status` | Get Off Limit Status |
| GET | `/v1/proficiencies` | Get Proficiencies |
| GET | `/v1/qualifications` | Get Qualifications |
| GET | `/v1/salary-types` | Get Salary Types |
| GET | `/v1/teams` | Get All Teams |

#### Custom-field definitions (3)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/custom-fields` | Show all Custom Fields |
| GET | `/v1/custom-fields/job-associated` | Show all Job Associated Custom Fields |
| GET | `/v1/nested-custom-fields` | Show Field Dependencies for all Entities |

#### Files (2)

| Method | Path | What it does |
|---|---|---|
| POST | `/v1/files` | Upload new files |
| GET | `/v1/files/{entity}/{slug}` | Get All Files |

#### Other (2)

| Method | Path | What it does |
|---|---|---|
| GET | `/v1/candidate-questions` | Get Candidate Questions |
| GET | `/v1/users/search` | Search for Users |
