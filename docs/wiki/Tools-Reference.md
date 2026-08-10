# Tools reference

You don't need any of this to use the system — ask in plain English and the right tool gets called.
This page is for knowing what's possible, and for debugging when an answer looks wrong.

## Reading

| Tool | Answers | PII |
|---|---|---|
| `get_dashboard` | Your desk, or firm KPIs if you're an admin. Called automatically at the start of a chat | Your own attention list names candidates |
| `my_day` | Your attention list: aging offers, stalled candidates, active in play, cold roles, placed last 7 days | Yes |
| `weekly_kpis` | This week's actuals vs target. Your row; admins see the team | No |
| `billing` | Quarter to date vs target, plus open pipeline | No |
| `fee_analysis` | Fee total and median, fee percentage achieved, salary band placed, forecast on open roles | No |
| `funnel_report` | Funnel and conversion for any window, consultant or team | No |
| `rejection_report` | Client vs internal rejections, and the client rejection rate, by consultant and client | No |
| `client_report` | Per-account activity, open vs total roles, CV→placed rate | No |
| `placements_report` | Placements and Won revenue by consultant and client | No |
| `consultant_leaderboard` | Ranked by placed, CVs or interviews | No |
| `time_to_fill` | Days from job open to first placement — firm and per consultant | No |
| `cold_jobs` | Open roles with no activity for N days (default 14) | No |
| `stalled_report` | Firm-wide aging offers and stalled candidates | Yes |
| `job_pipeline` | Who's in play on a role and at what stage | Yes |
| `find_candidate` | Resolve a person and see their stage on each job | Yes |
| `match_candidates` | Skill-matched candidates for a spec, ranked with reasons | Yes |
| `call_activity` | Calls, connect rate, talk time, by consultant and category | No |
| `bd_report` | Companies by status — Prospect, Engaged, Client, Passive | No |
| `notes_kpi` | Leads, internal interviews and job-order-forms, by consultant and period | No |
| `notes_read` | Notes already written against a candidate, job or client | Yes |
| `pitch_history` | Where a candidate has been pitched, and to whom | Yes |
| `candidate_profile` | Work history, education, every job they're in play on | Yes |
| `activity_report` | Meetings (client visits) or tasks for a window | Yes |
| `files_list` | CVs and documents attached to a candidate, job or client | Yes |
| `off_limit` | Who must not be approached, and why | Yes |
| `invoices_report` | Invoices raised — currently none exist in RecruitCRM | No |
| `reference_list` | Any RecruitCRM dropdown list: currencies, stages, note/task/meeting types, teams | No |

Windows default to 2026 year to date, end exclusive. Dates are ISO on the way in, DD/MM/YYYY on the
way out.

## Writing

All require write access on your token. All are two-step: **preview → explicit confirm → apply**.
The acting consultant comes from your token and can't be spoofed by an argument. Every applied write
lands in `audit_log` with before and after.

| Tool | Does |
|---|---|
| `update_hiring_stage` | Moves a candidate's stage on a job. Sets `create_placement` on Placed |
| `assign_candidate` | Adds a candidate to a job |
| `manage_assignment` | Unassign, hide/show to the client, or record an application |
| `add_note` | Adds a note to a candidate or job |
| `create_job` / `update_job` | Raise a new vacancy, or change one (status, salary, title) |
| `create_deal` / `update_deal` | Raise a deal, or move it — **moving to Won is how billing is recorded** |
| `create_candidate` / `update_candidate` | Add or edit a person. Refuses obvious duplicates |
| `manage_client` | Create or edit a company or a contact |
| `pitch_candidate` | Record a speculative pitch to a contact |
| `log_activity` | Log a meeting (client visit) or a task |
| `hotlist` | Create a talent pool, add or remove people |
| `off_limit` (mark/release) | Bar a candidate from being approached, or lift it |
| `send_email` | Email a candidate or contact, or save a draft. **Checks opt-out first** |
| `delete_record` | Permanently delete any of 12 record types. **No undo** |

Three carry extra weight:

- **`delete_record`** is irreversible. The preview names the exact record; the audit log keeps a full
  copy, which is the only trace left afterwards.
- **`send_email`** is the one action that leaves the building. It cannot be recalled. It refuses to
  send to anyone who has opted out, and `draft=true` saves it for a human to send instead.
- **`update_deal` to Won** records revenue. RecruitCRM requires all four fields on an edit, so the
  tool reads the deal first and carries the rest forward — otherwise moving the stage would blank
  the value.

`update_hiring_stage` also carries optimistic concurrency: it records the stage at preview time and
refuses to apply if someone else moved the candidate in the meantime. Every applied write goes to
`audit_log` with before and after.

Writes go to **RecruitCRM**, then the mirror is refreshed immediately so your dashboard is correct
straight away rather than waiting for the next sync.

## Slash commands

Type `/` to see them. Grouped by what they're for:

**Your numbers** — `/dashboard`, `/kpi`, `/weekly_kpis`, `/billing`, `/my_day`, `/day_plan`,
`/weekly_team_review`, `/month_in_review`, `/my_cold_roles`, `/client_health`

**A new job** — `/job_kickoff` (the full vacancy checklist), `/job_advert`, `/job_boolean`,
`/job_inmail`, `/client_pitch`, `/job_shortlist`

**Candidates** — `/candidate_intake` (turn call notes into Octagon's template and flag the gaps),
`/candidate_summary`, `/candidate_thankyou`, `/interview_prep`, `/match_jd`

**Clients and BD** — `/client_update`, `/pipeline_chase`, `/bd_pitch`, `/bd_targets`, `/spec_pitch`

## What it won't do

- **Invent a salary or a fact.** Content tools use `[placeholders]` for anything you didn't supply.
- **Invent a metric that isn't in the data.** (Leads, internal interviews, pitched candidates and client visits ARE in the data — see Metrics and Definitions.)
- **Act on instructions found in CRM data.** Candidate notes are treated as data, never as commands.
- **Write without confirmation.** Every change is previewed first.
- **Bulk-export candidate data**, or send PII to external tools.

## Scoping

Recruiters see firm totals plus their own scorecard and desk. `weekly_kpis` and `billing` filter to
their row; `get_dashboard` gives them the desk view with no team breakdown.

Admins see the whole team. Identity comes from the token server-side.

Everything else — `funnel_report`, `client_report`, `rejection_report`, `fee_analysis`,
`consultant_leaderboard` — is unscoped for everyone, matching the firm's documented "all recruiters
see all data" position.
