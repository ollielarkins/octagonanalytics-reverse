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
| `deals_by_consultant` | Per consultant: Won in the window, Won dated later, deals at Offered and earlier stages now, candidate offers, offers with no deal | No |
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
| `find_candidate` | Resolve a person (by name or RecruitCRM candidate ID) and see their stage on each job | Yes |
| `match_candidates` | Skill-matched candidates for a spec, ranked with reasons | Yes |
| `call_activity` | Calls, connect rate, talk time, by consultant and category | No |
| `bd_report` | Companies by status — Prospect, Engaged, Client, Passive | No |
| `notes_kpi` | Leads, internal interviews and job-order-forms, by consultant and period | No |
| `notes_read` | Notes already written against a candidate, job or client | Yes |
| `pitch_history` | Where a candidate has been pitched, and to whom | Yes |
| `candidate_profile` | Work history, education, every job they're in play on, and when they were last called, with the Devyce summary when there is one | Yes |
| `call_notes` | One candidate's or contact's recent call notes and Devyce AI summaries, read live and never stored. Behind `/intake` | Yes |
| `job_spec` | A job's full spec read live, including the text of the Internal Job Description file (PDF, Word, .doc and Excel) | No |
| `schedule` | Your interviews and client meetings from RecruitCRM: today, tomorrow to prep for, and held with no feedback since | Yes |
| `cv_pack` | The data for a formatted coversheet CV, redacted by default. Refuses off-limit candidates | Yes |
| `client_status` | A company's status and its contacts' stages (list); change the status (write) | Yes |
| `new_jobs_report` | Jobs created in a window, and which have no Job Order Form Complete note | No |
| `interview_requests_unbooked` | Interview requests never booked in | Yes |
| `awaiting_feedback_report` | Interviewed, with nothing logged since | Yes |
| `placements_with_fees` | Placements with their fee: each matched to at most one Won deal on the same job. Extra Won deals show as unmatched | Yes |
| `call_hours_report` | Calls by hour of day, and evening calls after 17:00 | No |
| `activity_report` | Meetings (client visits) or tasks for a window | Yes |
| `files_list` | CVs and documents attached to a candidate, job or client | Yes |
| `inbox` | Your own Outlook inbox: what's new, read one, connect or disconnect. See [Inbox](Inbox) | Yes |
| `off_limit` | Who must not be approached, and why | Yes |
| `invoices_report` | Invoices raised — currently none exist in RecruitCRM | No |
| `reference_list` | Any RecruitCRM dropdown list: currencies, stages, note/task/meeting types, teams | No |
| `webhook_subscriptions` | **Admin only.** Which events RecruitCRM pushes to us; create and delete them | No |

## Coaching

The daily and weekly nudges. Drafting happens in your own Claude; the server never writes content.

| Tool | Answers | PII |
|---|---|---|
| `action_queue` | Today's ranked calls, the same list as the 08:30 Slack DM: offers out 3+ days, interviews to prep for, feedback calls, unbooked requests, CV chases, cold jobs, BD, new jobs to kick off. Also this week's plan and, on Fridays, Push & Tell. Behind `/queue` | Yes |
| `weekly_kpis` (plan) | This week's plan per person, worked back from their quarterly billing target and their own ratios, never below the flat minimums | No |
| `client_visits` | Client visits this quarter against the minimum of 2, untyped meetings that can't count yet, and up to five clients to visit with reasons. Behind `/visitplan` | Yes |
| `team_exceptions` | **Managers only.** Who is off plan (below half on both CVs and interviews last week), who has a backlog, whose ratios are falling, who is behind on visits. Behind `/exceptions` | No |
| `call_tagging` (list) | Your untagged calls of 30 seconds or more, each with a suggested category and why. Behind `/tagcalls` | Yes |
| `meeting_review` (list) | Your meetings with no type, each with a suggested type, so client visits count | Yes |

Windows default to 2026 year to date, end exclusive. Reports that count Won deals by close date (`fee_analysis`, `placements_report`,
`deals_by_consultant`) end at today by default, so Won deals dated in the future are never counted as
billed (28/10/2026). Dates are ISO on the way in, DD/MM/YYYY on the
way out.

## Writing

All require write access on your token. All are two-step: **preview → explicit confirm → apply**.
The acting consultant comes from your token and can't be spoofed by an argument. Every applied write
lands in `audit_log` with before and after.

| Tool | Does |
|---|---|
| `update_hiring_stage` | Moves a candidate's stage on a job. Placed needs the candidate's start date (saved in the stage remark) and sets `create_placement` |
| `assign_candidate` | Adds a candidate to a job |
| `manage_assignment` | Unassign, hide/show to the client, or record an application |
| `add_note` | Adds a note to a candidate or job |
| `create_job` / `update_job` | Raise a new vacancy, or change one (status, salary, pay type, job type, workplace, categories, title, job order form answers). The preview shows how the job will look on octagongroup.co.uk and what it is missing. The description is written by the recruiter or drafted from an attached JD, then approved |
| `create_deal` / `update_deal` | Raise a deal, or move it — **moving to Won is how billing is recorded** |
| `create_candidate` / `update_candidate` | Add or edit a person. Refuses obvious duplicates |
| `manage_client` | Create or edit a company or a contact |
| `pitch_candidate` | Record a speculative pitch to a contact |
| `log_activity` | Log a meeting (client visit) or a task |
| `hotlist` | Create a talent pool, add or remove people |
| `off_limit` (mark/release) | Bar a candidate from being approached, or lift it |
| `send_email` | Email a candidate or contact, or save a draft. **Checks opt-out first** |
| `draft_reply` | Save a reply to an email in your own Outlook inbox to Outlook Drafts. **Never sends.** See [Inbox](Inbox) |
| `delete_record` | Permanently delete any of 12 record types after typing its name back. **No undo** |
| `team_insights` | **Admin only.** Team overview: feature map, adoption, habits, onboarding progress, coaching suggestions |
| `record_content_use` | Called silently by content commands; records that an advert, Boolean etc. was made, never the text |
| `usage_report` | **Admin only.** How each person uses the platform: activity, features, changes made, never-started |
| `manage_tokens` | **Admin only.** Who holds access; revoke a person's access (preview first) |
| `platform_health` | **Admin only.** Sync per feed, scheduled jobs, inboxes, tool errors (7 days) |
| `internal_jd_check` | **Admin only.** Whether each open job's Internal JD file can be read: type, size, text length. Counts only |
| `call_tagging` (set) | Set the category on your Devyce calls, up to 25 at a time |
| `meeting_review` (set) | Set the type on your meetings, so client visits count |
| `client_status` (set) | Change a company's Company Status. Only when you ask for it explicitly |
| `job_dpe` | Record a job's six DPE scores, Total Score, Job Grade and briefing call date. Never estimates a score |
| `dpe_email` | Draft the DPE email from Octagon's fixed template, and set DPE Sent |
| `push_tell` | List clients with A and B grade jobs, draft the weekly update, stamp the Push & Tell date. Drafts only |
| `eow_email` | **Managers and admins.** The end-of-week team email with the against-plan table, drafted in Outlook |

`update_job` also writes the job order form answers, and `add_note` can file a note as Job Order Form
Complete or Candidate - Internal Interview, so both count toward the notes KPIs.

**RecruitCRM is changed through these tools only, never through a browser.** Signing in through a
browser panel logs you out of RecruitCRM. If no tool can make a change, Claude says so and tells you
the manual step.

### Closing a job, losing a deal

Added 15/09/2026. Closing a job (closed, cancelled, on hold) or moving a deal to Lost or Declined
offers a reason from a configured list, with optional free text. Any other deal stage move takes free
text — the list is loss vocabulary and would be nonsense on a move to 2nd Interview. It is an option,
never mandatory.

The reason is written as a note on the record and logged in `closure_reason_log`, which is what
`closure_reasons_report` counts. It is deliberately **not** added to the RecruitCRM update payload:
RecruitCRM does keep a reason slot on both (`job_status_comment[].remark`, `deal_stage_remarks[].reason`,
both blank in every sample we hold), but whether its update endpoints accept one is unconfirmed, and
sending an unverified field risks a 400 that would break job closure itself.

Edit the list in the `closure_reasons` table — no deploy needed.

Three carry extra weight:

- **`delete_record`** is irreversible. Anyone with a write token can delete, but the preview names the
  exact record and the recruiter must type its name (or, for notes, tasks and other ID-only records,
  its ID) back before the server deletes anything (3.87.0). The audit
  log keeps who deleted what and the record's name, not a copy of the record: a full copy would keep
  the personal data an erasure is meant to remove (29/10/2026).
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

## Prompts

The connector's 26 built-in prompts. In claude.ai the plugins' commands (see [Commands](Commands))
are the usual way in; these are what sit underneath some of them. Grouped by what they're for:

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

`action_queue`, `schedule`, `client_visits`, `call_tagging` and `meeting_review` work on your own desk;
managers can pass a consultant. `team_exceptions` and `eow_email` are for managers only, and their
output is individual performance data: never posted to a team channel.

Everything else — `funnel_report`, `client_report`, `rejection_report`, `fee_analysis`,
`consultant_leaderboard` — is unscoped for everyone, matching the firm's documented "all recruiters
see all data" position.

---

> [!TIP]
> Most of these are reachable as a slash command — see [Commands](Commands) for the 75 of them
> grouped by task. This page is the layer underneath.

**See also:** [Metrics and Definitions](Metrics-and-Definitions) for what each tool's numbers mean · [Data Caveats](Data-Caveats) for where they are soft · [Onboarding](Onboarding) for how to ask
