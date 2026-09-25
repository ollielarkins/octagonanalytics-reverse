# GDPR Review — technical findings

Status as of 25/09/2026. Part of ROADMAP Milestone 7 ("GDPR review").

This is an engineering review of what personal data the platform holds, where it goes, how long it
stays and who can reach it. It is **not legal advice**. The decisions at the end belong to Octagon
as data controller (and its DPO, if it has one); the technical fixes can proceed without them.

---

## 1. Roles and where data flows

RecruitCRM is the system of record. This platform mirrors part of it into Supabase and exposes it to
recruiters through Claude, Slack and email digests.

| Party | Role | Data it receives | Location |
|---|---|---|---|
| RecruitCRM | processor (system of record) | everything | per RecruitCRM contract |
| Supabase | processor (hosting) | the mirror below | **eu-west-1, Ireland** |
| Anthropic (Claude) | processor | whatever a tool returns in a conversation: candidate names, stages, note text via `notes_read` | per Anthropic terms |
| Slack | processor | digests and slash-command output (aggregates, some names) | per Slack terms |
| Resend | processor | email digests | per Resend terms |
| GitHub | none (code only) | no personal data; the repo is **public**, so it must stay that way | — |

**Check:** each of these should be listed in Octagon's record of processing and covered by a DPA.
The platform cannot verify that; someone at Octagon needs to.

## 2. Personal data held

| Where | Whose | What | Notes |
|---|---|---|---|
| `candidates` (52,391) | candidates | name, email, city, country, skills, source, off-limit reason | back to 2018 |
| `candidates_archive` (3) | candidates deleted in RecruitCRM | full row | **kept indefinitely** — see 4 |
| `notes` (100,600) | candidates, contacts | free-text notes up to 4,000 chars | **highest risk**: unstructured, can hold salary, health, reasons for leaving, anything a recruiter typed |
| `candidate_stage_events` (44,920) | candidates | name, job, stage, date | |
| `webhook_events` | candidates, contacts | raw RecruitCRM payloads | purged daily (`purge-webhook-events`); oldest row 7 days |
| `audit_log` | candidates, staff | before/after of every write made through Claude | no retention limit |
| `consultants`, `call_activity`, `mcp_call_log` | Octagon staff | name, email, call records, tool usage | employee monitoring data |
| `feedback` | staff | name, email, message | 1 row |

Phone numbers, CVs and salary fields are **not** mirrored as structured columns — good, and worth
keeping that way.

## 3. Access

- Recruiters reach data only through per-user tokens (`mcp_tokens`, hashed). 6 active: 3 admin,
  all 6 can write. None unused for 30+ days.
- RLS is on for every table; the anon key reads nothing directly. `deal_pipeline_by_stage` was the
  exception until 25/09/2026 (fixed in 0084).
- **Critical — open sign-up + blanket `authenticated` read policies.** Supabase Auth has public
  email sign-up enabled (`disable_signup: false`), and 0001 gave the `authenticated` role
  `using (true)` read on `candidates`, `candidate_stage_events`, `deals`, `audit_log`,
  `call_activity`, `clients`, `jobs`, `consultants` and more. Anyone could register, confirm an
  email, and read all 52,391 candidates' names and emails over the REST API. Nothing in the
  platform uses Supabase Auth — all access is service-role behind per-user tokens — and
  `auth.users` and `auth.audit_log_entries` are both empty, so no one has done this. Fix: turn off
  sign-up **and** drop the `authenticated` policies.
- **Open exposure:** `dashboard-data` returns firm revenue and per-consultant figures to anyone
  with the URL, and the URL is in this public repo. Per-consultant performance is employees'
  personal data. See README.
- **Open:** five SECURITY DEFINER report functions (including `placements_with_fees`) are
  executable by any signed-in Supabase user — and given open sign-up, that is anyone.

## 4. Retention and erasure

The mirror follows RecruitCRM, so retention is mostly RecruitCRM's retention. Deletions **mostly**
propagate:

| Deleted in RecruitCRM | Reaches the mirror? |
|---|---|
| candidate | yes — retire pass, twice daily — **but moves to `candidates_archive` and stays there** |
| client, job, deal, consultant | yes — reconciles, soft delete (`deleted_at`) |
| note | **no** — there is no notes reconcile; a deleted note stays in the mirror forever |
| stage history | pruned on each candidate's history walk; **not** for retired candidates (7 orphaned events today) |

So an erasure request actioned in RecruitCRM is **not** fully honoured here: the candidate row
survives in the archive, their notes survive in `notes`, and their stage events can survive in
`candidate_stage_events`.

## 5. Findings, in priority order

| # | Finding | Fix | Needs a decision? |
|---|---|---|---|
| 0 | **Open sign-up lets anyone read the candidate mirror** (see 3) | disable sign-up in Supabase Auth; drop every `authenticated` read policy | no — do immediately |
| 1 | Erasure doesn't propagate to archive, notes, or orphaned stage events | purge archive rows after a short reinstatement window (e.g. 30 days); add a notes reconcile; delete events for retired candidates | window length |
| 2 | `dashboard-data` public | remove it (the connector dashboard replaced it) | no |
| 3 | `notes.description` mirrors all free text back to 2018 | `notes_kpi` needs only type and author. Either stop mirroring text and fetch it live in `notes_read`, or keep a rolling window | yes — whether mirrored note text is needed |
| 4 | `audit_log` has no retention | keep N months, then drop before/after bodies but keep the event | N |
| 5 | Report functions executable by `authenticated` | revoke | no |
| 6 | Note text and candidate data go to Anthropic in conversations | covered by the org instructions ("internal only, no bulk export"); confirm Anthropic is in the processing record | confirm |
| 7 | Staff monitoring (calls, tool usage, per-person KPIs) | make sure staff are told, in the employee privacy notice | confirm |
| 8 | No backups | see DISASTER-RECOVERY.md | yes |

## 6. Decisions for Octagon

1. Reinstatement window for retired candidates before permanent deletion (proposed: 30 days).
2. Does the platform need to **store** note text, or only read it live? (Proposed: read live.)
3. Audit log retention (proposed: 24 months full, event only after).
4. Confirm Supabase, Anthropic, Slack and Resend are in the record of processing with DPAs.
5. Confirm the employee privacy notice covers call and KPI monitoring.
