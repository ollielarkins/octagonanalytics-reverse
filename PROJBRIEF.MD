# Octagon Recruitment Analytics Platform — Project Brief & Handoff

*A standalone brief. It assumes no prior knowledge of the project and is intended to bring a new engineer or stakeholder fully up to speed. The companion **Build Roadmap** document breaks the delivery into ordered milestones; this brief explains the what, why, and current state that sit behind that plan.*

---

## 1. Overview

Octagon Recruitment Group currently reports on its recruitment performance through **manual spreadsheets**. Numbers are pulled by hand, updated manually, and are stale the moment they're produced. This is slow, error-prone, and can't answer ad-hoc questions.

This project replaces that with a **live analytics platform**: an always-current view of the firm's recruitment data, sourced automatically from the CRM, with two ways to consume it —

1. **Dashboards** for viewing standard reports, and
2. **A Claude interface** recruiters talk to directly, to ask questions in plain English *and* take defined actions.

The goal is a single, trusted source of live recruitment analytics that removes manual reporting entirely.

---

## 2. Who it's for

- **Primary users:** recruiters/consultants at Octagon Recruitment Group.
- **Access model:** all recruiters can see all data — placements and performance are **not** siloed per consultant. This is a deliberate decision (see §6).
- **Stakeholders / scale:** *To be confirmed* — number of recruiters, number of teams, and the internal owner/sponsor of the platform should be documented here before rollout planning.

---

## 3. Architecture at a glance

The platform is a pipeline from the CRM (the system of record) into a clean analytics store, with a shared definition layer that both consumption surfaces read from.

```
                         ┌─────────────────────────┐
                         │       RecruitCRM         │   ← system of record
                         │  (candidates, jobs,      │     (placements happen here)
                         │   placements, deals…)    │
                         └───────────┬──────────────┘
                            sync ↓        ↑ actions (write-back)
                                   ↓        │
                         ┌─────────────────────────┐
                         │        Supabase          │   ← clean, queryable
                         │  (Postgres data model)   │     copy of the data
                         └───────────┬──────────────┘
                                     │
                         ┌───────────┴──────────────┐
                         │    Semantic / metrics    │   ← ONE definition of each
                         │  layer (shared views)    │     metric, used by both below
                         └─────┬──────────────┬─────┘
                               │              │
                    ┌──────────┴───┐   ┌──────┴──────────────┐
                    │  Dashboards  │   │  Claude (direct)    │
                    │  (view)      │   │  ask questions +    │
                    │              │   │  take actions ──────┼──► RecruitCRM
                    └──────────────┘   └─────────────────────┘
```

**Data flow in words:**
1. **RecruitCRM** is the source of truth — all recruitment activity happens there.
2. Data **syncs into Supabase**, giving Octagon its own clean, queryable copy that isn't limited by RecruitCRM's native reporting.
3. A **semantic layer** defines each metric exactly once, so everything downstream agrees.
4. **Dashboards** and **Claude** both read from that same layer.
5. When a recruiter asks Claude to *change* something, the write goes **back to RecruitCRM** (the system of record), not to the Supabase copy — the copy updates via the normal sync.

---

## 4. The Claude interface (the distinctive part)

Recruiters use **Claude directly** as an interface to the platform. It has two capabilities:

- **Ask questions (read):** recruiters ask in plain English — "how did the tech team do last quarter?", "which of my roles have gone cold?" — instead of navigating a dashboard. Claude answers from the **same semantic layer** the dashboards use, so its answers and the dashboards never disagree.
- **Take actions (write):** when a recruiter *explicitly* asks, Claude can perform a small set of **defined actions** back in RecruitCRM — e.g. update a candidate's hiring stage, assign a candidate to a job. Each action is confirmed by the recruiter before it runs and is fully audited.

Claude reads and writes through a **mediated layer** (a custom API / scoped access), **not** by running free-form SQL against the database or holding broad credentials. This is the core safety design (see §6 and §9).

---

## 5. Current state of the build

The project was started but is early-stage. As of this brief:

- A Supabase project exists — **"Reporting for CRM"** (`eu-west-1`, project ref `kzcmssldvtjnbwwunuwm`). It was found **paused** (free tier) and restored for inspection.
- It contains **8 tables** but **no data** — the schema is scaffolded, nothing has been synced yet.
- **No sync pipeline, edge functions, or migration history exist yet.** The schema appears to have been built by hand.
- An **audit of the schema** surfaced issues to fix before data lands (see §7 and §8).

Being empty is an advantage: the data model can be corrected now at near-zero cost, before months of data make changes painful.

---

## 6. Key decisions already made

| Decision | Rationale |
|---|---|
| **RecruitCRM is the system of record; Supabase is a synced copy** | Reporting shouldn't be hostage to RecruitCRM's native reporting limits; a clean local copy is queryable and flexible. |
| **All recruiters can see all data** | It's an internal tool at one firm; per-recruiter read boundaries aren't needed, which simplifies the whole read path. |
| **Recruiters use Claude directly** | Natural-language Q&A over the data is the headline value beyond fixed dashboards. |
| **Claude reads/writes via a mediated layer, not free-form SQL** | Guarantees numbers match the dashboards and prevents a generated query from doing something unintended or exposing data. |
| **Writes go to RecruitCRM, not the Supabase copy** | Writing to a synced mirror would be overwritten on next sync or cause drift; the system of record must own the change. |
| **Every AI action is confirmed by the recruiter and audited** | "Only act when explicitly asked" can't be enforced by the model alone; confirmation and audit make it real. |
| **Data stays in the EU (`eu-west-1`)** | Candidate PII under GDPR. |

---

## 7. Data model summary

The 8 tables fall into two groups:

- **Relational core (well-formed):** `consultants`, `clients`, `jobs`, `placements` — UUID keys, proper foreign keys, `recruitcrm_id` as the external key. Supports the headline metrics (placements, fees, time-to-fill, pipeline, salary bands).
- **Event / activity tables (flatter):** `deals`, `daily_activity`, `deal_stage_events`, `candidate_stage_events` — these reference consultants and companies by **name/slug** rather than by key, and don't currently join cleanly to the core.

**Why the split exists (an important finding):** RecruitCRM's API is **slug-centric** — every entity has its own numeric `id`, but when one entity references another, the payload gives a **slug** (and often a name), not the target's numeric id. So the slug-based event tables are a *faithful mirror of the source*, not a mistake. The correct fix is to **land the slugs as they arrive, then resolve them to internal keys during sync** — which requires adding a unique `slug` to `jobs` (currently missing) and unifying consultant identity on `recruitcrm_id`.

---

## 8. Known issues to fix before data lands

1. **Row-Level Security gap:** `deal_stage_events` has RLS disabled (every other table has it on). It must be enabled *with* an appropriate policy — enabling it with no policy blocks all access.
2. **Consultant identity is referenced three different ways** across tables (UUID FK, numeric RecruitCRM id, and free-text name). This must be unified on `recruitcrm_id` or Claude/dashboards will give inconsistent answers to "…by consultant/team" questions.
3. **`jobs` has no `slug` column** — needed to resolve slug-based deal/event references into keys.
4. **`deals` is orphaned** from the relational core — resolve its slugs to foreign keys on sync.

---

## 9. Security & compliance

- **RLS on every table**, with policies matching the "all recruiters see all data" model.
- **RecruitCRM API token held server-side only**, never exposed to the client — required by RecruitCRM's own guidance. A mediating server sits between any client and the CRM API.
- **Prompt-injection defence:** data flowing in from RecruitCRM free-text fields (candidate notes, names) is treated as untrusted. Claude never treats instructions found *in data* as a recruiter request; it acts only on explicit, confirmed input.
- **Audit trail** for every write action: who, what, when, before/after, and that it was performed via Claude.
- **GDPR:** candidate PII kept in-region (EU); retention and access justification to be documented.

---

## 10. RecruitCRM integration facts

- The **Open API requires a Business plan or higher**; only the Account Owner manages API keys.
- The API supports **reading and writing** candidates, companies, contacts, and jobs (REST, Bearer token, base `api.recruitcrm.io/v1`; consultants are the `/users` endpoint).
- Relevant **write endpoints exist**: assign a candidate to a job, update a candidate's hiring stage (marking "Placed" also captures a salary field), update job fields, create/edit candidate.
- **Statuses/stages use integer IDs**, so a stage-id → name lookup is needed.
- **Webhooks** exist for the events that feed the sync (candidate assigned, hiring stage updated, job status updated, note added, deal updated, etc.).

---

## 11. Scope & non-goals

**In scope:** live analytics/reporting on recruitment data; dashboards; a direct Claude interface for questions and a defined set of write actions; the sync pipeline and data model that support them.

**Out of scope (non-goals):**
- Not a replacement for RecruitCRM — RecruitCRM remains the system of record and day-to-day ATS/CRM.
- No candidate-facing features (no public career pages, applicant portals, etc.).
- No unrestricted AI write access — only the small, defined, audited action set.
- Not a data warehouse for non-recruitment data.

---

## 12. Open questions / risks

- **`daily_activity` data source is unconfirmed.** Its 15 counters (e.g. `cv_sent`, `first_interview`, `call_time_minutes`) don't map to an obvious RecruitCRM API object and may be *derived* or imported from a report export. Its ingestion path can't be finalised until this is known.
- **Exact write-action payloads unconfirmed.** The endpoints are known to exist, but the precise request bodies (e.g. for updating hiring stage) couldn't be read from the JavaScript-rendered official docs. Best closed by testing against the live API with a token.
- **Plan tiers not yet confirmed** — RecruitCRM Business+ (for API) and a non-pausing paid Supabase tier are prerequisites.
- **"Live" is undefined** — the acceptable data-freshness target (e.g. "within N minutes") should be agreed; true real-time is rarely needed for this kind of reporting.

---

## 13. How the work is structured

Delivery is broken into eight ordered milestones (M0–M7) in the companion **Build Roadmap** document. The guiding principle is **trustworthy reads before writes**: the schema, sync, and shared metric definitions come first; dashboards and Claude's question-answering next; Claude's write-back capability is deliberately gated until the read side is trusted; hardening and rollout conclude.

Summarised: **get the data model right → sync RecruitCRM into it reliably → define metrics once → show them (dashboards) and let Claude answer from them → then, carefully, let Claude act back into RecruitCRM → harden and roll out.**

---

## Glossary

- **RecruitCRM** — the recruitment ATS/CRM that is Octagon's system of record.
- **Supabase** — a hosted Postgres platform; here, the clean analytics copy of the data.
- **Semantic / metrics layer** — a single shared definition of each metric (as database views), so dashboards and Claude always agree.
- **RLS (Row-Level Security)** — Postgres feature controlling which rows a given role can access.
- **Slug** — RecruitCRM's string identifier used to reference an entity from another entity's data.
- **System of record** — the authoritative source for a piece of data (here, RecruitCRM).