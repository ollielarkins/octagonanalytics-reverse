# Design Decisions — Octagon Analytics

Running log of the decisions behind the schema and semantic layer. Each entry: the decision, why, and status. This exists so the "one canonical definition per metric" promise is written down, not just implied by SQL.

---

## D1 — Canonical event source for the funnel: `candidate_stage_events`

**Decision.** All funnel/activity metrics (cv_sent, interview stages, offers, placements, conversion ratios, stage timing) are computed from **`candidate_stage_events`** — and nothing else. `deal_stage_events` and `daily_activity` are **not** blended into the funnel.

**Why.** The audit found the *same* metric computed from three different tables, which cannot agree. `candidate_stage_events` is the richest and most granular source (candidate_id, job_slug, consultant, stage_metric, event_date), so it's the natural single source of truth.
- `deal_stage_events` is deal-level, not candidate-level, and had RLS off — it's demoted to deal-stage-history only.
- `daily_activity` is a pre-aggregated import of **unconfirmed provenance** (open question in the brief). It is kept as a *separate* "reported activity" fact and surfaced in its own view, clearly labelled as a different source — never summed together with event-derived counts.

**Status:** **Confirmed as-built.** `candidate_stage_events` is now populated by the live sync's `history` mode (hiring-stage history per candidate, mapped via `stage_lookup`), and is the sole source for every funnel/consultant metric and for `funnel_report` (0014). Pre-2026 history is sparse in RecruitCRM, so reporting defaults to a 2026-onward window — see [D8].

**Update 10/08/2026 — `daily_activity` removed (0042).** The provenance question was never answered, so no ingestion path was ever built and the table stayed a one-off import. Both of its intended roles had since been filled: `candidate_stage_events` for the funnel, and `call_activity` (0027, Devyce) for activity/leading indicators. Half its columns — `lead`, `pitched`, `internal_interview`, `job_order_form_complete`, `prospect_bd`, `client`, `call_time_minutes`, `jobs_added`, `assigned` — were zero in every row, and the populated ones disagreed with the event stream by roughly 6× (Jan 2026: 56 `cv_sent` vs 256). Table and `reported_activity_daily` dropped. If leads / pitched candidates / internal interviews are tracked in future, build the capture deliberately rather than reviving this table.

---

## D2 — Stage taxonomy: `stage_metric` is canonical; `stage_name` is display-only

**Decision.** Views key off the machine token **`stage_metric`** (`cv_sent`, `interview_request`, `first_interview`, `second_interview`, `offered`, `placed`, `rejected_consultant`, `rejected_client`). `stage_name` ('CV Sent', '1st Interview', …) is human-facing only. A lookup table maps RecruitCRM integer stage IDs → (`stage_metric`, `stage_name`).

**Why.** The legacy views mixed the two (one funnel view keyed off `stage_name`, others off `stage_metric`), so they silently diverged. Picking one canonical key removes that class of bug. RecruitCRM uses integer stage IDs, so a lookup is needed anyway.

**Status:** **As-built.** `stage_lookup` maps confirmed RecruitCRM stage ids → `stage_metric` (0008); the sync's `history` mode and all views key off `stage_metric`.

---

## D3 — Reporting exclusions live in a table, not hardcoded in SQL

**Decision.** The people currently hardcoded as `consultant <> ALL('Laura','Matthew','Aimee')` move into a table `public.reporting_exclusions(consultant_name text, reason text)`. Every consultant-facing view joins/anti-joins to it, so the rule is applied **once, consistently**.

**Why.** The exclusion was applied in some views and not others → two "consultant funnel" views returned different numbers. Hardcoded names in 10+ view bodies are unmaintainable. One table = one rule, editable without DDL.

**Open question:** who are Laura/Matthew/Aimee and why excluded (directors/managers not measured on consultant productivity)? Confirm the list is correct and complete before data lands.

**Status:** Superseded in practice. With owner attribution ([D9]) and a 2026-onward window ([D8]), the funnel is driven by who *owns* jobs; non-producing directors simply own few/no jobs and fall out naturally, and leavers are handled as `active = false` rather than a hardcoded name list. The `reporting_exclusions` table remains available as an override but is not the primary mechanism.

---

## D4 — One definition of "placement"

**Decision.** Two candidate definitions exist: (a) a row in the `placements` table, (b) `count(stage_metric='placed')` in the event stream. Until real data lets us reconcile them, the **canonical "placement" for funnel/consultant/team metrics is the event-stream `placed` count** (b), because the whole funnel is built on `candidate_stage_events` (D1). The `placements` table is treated as the **finance/fee source of record** (fee_amount, placement_date, salary) and reconciled against (b) once data lands.

**Why.** Mixing the two silently double-counts or disagrees. Keep the funnel internally consistent (all from one source), and treat `placements` as the authoritative money view, then reconcile.

**Status:** **As-built** for the funnel — the canonical "placement" is the event-stream `placed` count, and write-back sets `create_placement=true` when moving a candidate to Placed (so the two stay coupled at source).

**Update 10/08/2026 — the `placements` table will never be the fee source.** `GET /v1/placements` was probed directly: it exists and returns paginated data, but a placement record carries **no money at all**. Its fields are `id, archived, company_slug, candidate_slug, job_slug, contact_slugs, deal_slugs, custom_fields, currency_id, joining_date, created_on/by, updated_on/by`, and `custom_fields` came back empty across a full page. A placement in RecruitCRM is a *join record* — candidate ↔ job ↔ company ↔ deal — not a finance record. The fee lives on the deal (see [D5]). If placements are ever synced it should be for that join, particularly `deal_slugs`, which is the only route to a per-placement fee.

---

## D5 — Revenue vs pipeline are distinct, explicitly defined

**Decision.**
- **Pipeline value** = `sum(deal_value)` over **open** deals (not Won/Lost).
- **Revenue (won)** = `sum(deal_value)` where `deal_stage = 'Won'`, bucketed by **`close_date`** (the month it closed), not `created_date`.
- ~~**Fees** = `sum(fee_amount)` from `placements` (the finance source of record).~~ **Superseded — see the update below.**

**Why.** Legacy views conflated these: `monthly_revenue` filtered Won but bucketed by created_date; `client_revenue`/`funnel_stage` summed all stages as if revenue. Naming each precisely stops "revenue" meaning three things.

**Status:** **As-built**, with the fee definition corrected on 10/08/2026.

**Update 10/08/2026 — the fee IS the Won deal value.** There is no `placements.fee_amount`; the placement record holds no money (see [D4]). `deals.deal_value` was already the fee all along, which the distribution confirms: Won deals have a median of £6,432 and 713 of 862 fall between £2,000 and £30,000 — fee-shaped, not salary-shaped.

The components are deal custom fields, landed by migration 0043:

| Field | Column |
|---|---|
| Annual Salary | `deals.annual_salary` |
| Percentage of Annual Salary | `deals.fee_percentage` |
| Currency | `deals.fee_currency` |
| Start date / End date | `deals.start_date` / `deals.end_date` |

This reconciles: **629 of 722** deals holding both components satisfy `deal_value = annual_salary × fee_percentage ÷ 100` to within £1, and the median fee percentage is **18.0%** (5th–95th percentile 15–20%). Two rows carry a nonsense percentage (one reads 7000) — data entry to be corrected at source, and the reason the median rather than the mean is the figure to quote.

Jobs also carry a `Forecast Fee (£)` custom field, landed as `jobs.forecast_fee` — a per-role forward indicator, £1,546,032 across open roles at the time of writing.

So the canonical definitions are:
- **Billing / fee revenue** = `sum(deal_value)` where `deal_stage = 'Won'`, bucketed by `close_date`.
- **Fee components** = `annual_salary` × `fee_percentage` on the deal.
- **Forecast** = `sum(jobs.forecast_fee)` over open roles.

---

## D6 — Views are `security_invoker`; access via table RLS policies

**Decision.** All semantic-layer views are recreated with `WITH (security_invoker = on)`. Base tables get RLS policies granting **`authenticated` read on all rows** (the "all recruiters see all data" model); `anon` gets nothing (candidate PII).

**Why.** The 19 legacy views were `SECURITY DEFINER` (flagged ERROR ×19 by Supabase) and bypassed RLS — they were the *only* reason data was readable, since base tables had RLS on but no policies. Invoker views + real policies make access explicit, auditable, and consistent between dashboards and Claude.

**Status:** Structural policies applied in migration 0001; view recreation in the canonical-views migration.

---

## D7 — Consultant identity unified on `recruitcrm_id`

**Decision.** `consultants.recruitcrm_id` (bigint, unique) is the canonical consultant key. Event tables keep the raw `consultant` (name) and `consultant_id` (RecruitCRM id) **as landed from the source**, but every view resolves consultant identity by joining on `recruitcrm_id`. Free-text name columns become display-only. `daily_activity.consultant` (name-only) is resolved to `recruitcrm_id` during sync.

**Why.** Consultant was referenced three ways (UUID FK, bigint id, free-text name); "…by consultant/team" answers would otherwise disagree. One canonical key fixes it.

**Status:** **As-built.** The sync resolves consultant identity on `recruitcrm_id`; views join on it; owner attribution ([D9]) rests on this key.

---

## D8 — RecruitCRM is the single source of truth (SSOT); Supabase is a live mirror

**Decision.** RecruitCRM is the **single source of truth**. Supabase is a live, always-current mirror of the RecruitCRM API output (via the M2 sync), and everything downstream (semantic layer, dashboards, Claude) reads from that mirror. The current data is a stale one-off hand-import and will be **replaced** by the live sync.

**Consequences.**
- The "Ratios 2025-26" spreadsheet is **NOT** the source of truth — it becomes a *validation reference* only (see [[octagon-ratios-spec]]).
- Where the spreadsheet disagrees with RecruitCRM, the platform reports the **RecruitCRM** figure. Closing the gap is a **data-entry/process** fix (get the activity logged in RecruitCRM), not a reason to bend the platform to the sheet.
- A live mirror guarantees `Supabase == RecruitCRM`; it does **not** guarantee `Supabase == spreadsheet`. That's expected and acceptable under SSOT.
- The chosen canonical funnel source (D1) must be whatever RecruitCRM actually feeds once the sync is live; revisit D1 against real synced data (candidate_stage_events had almost no pre-2026 history in the stale import).

**Status:** **Decided by the user 2026-08-03; now realised.** The live sync (M2) is running; the mirror equals RecruitCRM to ~2-min freshness. The leg-A finding confirmed the sheet was a *manual tally the CRM never contained*: ratios agree (~0.21–0.36) but absolute counts diverge (Jan 2025: mirror 107 vs sheet 223) because pre-2026 activity was never logged. The platform reports the CRM figure; the divergence is a data-entry/process gap, exactly as this decision anticipated.

---

## D9 — Per-consultant attribution is by job owner, not `updated_by`

**Decision.** Every per-consultant metric credits the **owning consultant of the job** the
event belongs to (`jobs.consultant_id`), **not** the user who logged the event
(`updated_by`). `funnel_report` (0014) and the dashboard's consultant table both use owner
attribution.

**Why.** RecruitCRM's `updated_by` records whoever *clicked*, which includes admins, coordinators,
and colleagues moving stages on each other's candidates. Attributing by `updated_by` produced
**impossible funnels** — one consultant credited with 62 CVs but 289 first interviews. Job owner
is the stable "whose desk is this" key and matches how the firm thinks about performance.

**Consequence.** `updated_by` is still captured and set on **write-back** (so RecruitCRM's own
activity log attributes the acting consultant), but it is never the reporting attribution key.

**Status:** **Decided & as-built 2026-08-04. Superseded for activity metrics 02/09/2026** (migration
0066): funnel activity, `kpis_report` and `consultant_leaderboard` now credit whoever moved the stage,
falling back to the job owner. Against RecruitCRM's January report that matched 20 of 27
per-consultant figures, where job owner scattered (one desk 184 against their 105) and credited people
with activity on jobs they inherited later. The `updated_by` problem above was handled by counting
distinct candidate-job pairs (0065). Desk views (`cold_jobs`, `stalled_report`, `time_to_fill`,
`placements_report`, `rejection_report`) stay owner-attributed: they answer "whose desk is this".

---

## Recruiter inboxes: metadata only, drafts only, opt-in

**Decision.** Recruiters can connect their own Outlook inbox (0085, `inbox-sync`, `inbox` and
`draft_reply` tools). The platform stores envelope metadata only (sender, subject, time, thread, a
rule-based category), purges it after 30 days, fetches a body only when its owner asks, and can save
reply drafts but cannot send. Each recruiter opts in; nobody's mailbox is read because they hold a token.

**Why.** Requested 13/10/2026 to cut time on routine email. Bodies carry candidate and client personal
data, so holding only what the "what's new" summary needs keeps the GDPR footprint small. The Graph
permission is Mail.ReadWrite without Mail.Send, so a bug cannot send mail. Categories are rules rather
than a model so they are predictable and explainable; offers, pay, fees, complaints and legal are
"never" and are checked before "routine".

**Consequence.** No server-side AI call: drafting happens in the recruiter's Claude chat, so email
content goes to Anthropic only when the recruiter asks for a draft, under the same terms as the rest
of their chat. Before more recruiters connect, a short DPIA entry should record the processing.

**Status:** **Decided & built 13/10/2026** (octagon-mcp 3.46.0). Not live until the Microsoft 365 app
registration and secrets are in place; see docs/wiki/Inbox.md.

---

## Call notes and Devyce AI summaries: read live, never mirrored

**Decision.** Call notes (including the Devyce AI call summary) stay out of the mirror. The sync keeps
dropping `call_notes` from `call_activity`. `call_notes` (octagon-mcp 3.70.0) reads them live from
RecruitCRM's `/call-logs/search`, for one candidate or one contact per call, and writes an
`audit_log` row (`read_call_notes`) for every read. `candidate_intake` now pulls the latest Devyce
summary itself instead of asking for a paste, and can save the finished intake as a
"Candidate - Internal Interview" note through `add_note` (`note_type: internal_interview`), preview
then confirm.

**Why.** Probe on 20/10/2026, which returned no call content: all 50 recent call logs had
`call_notes` set, as HTML (median 571 characters), and 38 were marked Devyce. Recruiters were still
pasting transcripts into chat. A live, single-person read gives the same help without holding
call content at rest. Only `/call-logs/search` honours `related_to`. The plain `/call-logs` list
ignores it and returns everyone's calls, so the tool re-filters on `related_to` and fails closed.

**Not decided.** The internal interviews KPI counts whatever is filed as that note type, so saving
an intake under it is opt-in per call and the recruiter is asked first. `note_type_id` on
`POST /notes` has not been tested live yet: check the first internal-interview save in RecruitCRM.
Suggesting Devyce call tags from the summary is a later step.

**Follow-up 26/10/2026.** `call_notes` had no calls in its first six days, because nothing led
recruiters to it. `candidate_profile` (3.73.0) now returns `latest_call`: date, caller, and whether
a Devyce summary exists, never the text, so it needs no audit row. The `/intake` skill
(octagon-reporting 0.1.5) and `/interviewprep` read the summary through `call_notes`.

**Status:** **Live** since 26/10/2026 (octagon-mcp 3.73.1, migration 0104).

---

## Placements and Won deals: one deal per placement

**Decision.** A placement is worth one Won deal. `placement_deal_match()` (migration 0109) pairs
each placement with at most one Won deal on the same job, and each deal with at most one placement:
the candidate's name in the deal name first (a first name that a consultant also has does not
count), then the deal created nearest the placement date. Any other Won deal is a separate fee,
listed by `placements_with_fees` as unmatched and never added to a placement. A placement with no
Won deal 14 days after placing is flagged overdue.

**Why.** Deals carry a job but no candidate, so each placement took the job's latest Won deal: on
26/10/2026 that let two placements share one deal and ignored the rest on jobs with several Won
deals (retainer stages, contract invoices). The "£0 billed" Bhav saw for Corintech and Moonshot on
19/10/2026 was `placements_report` counting Won revenue by close date (31/12/2026); it now also
gives `placed_value`.

**Status:** **Live 26/10/2026** (octagon-mcp 3.74.0, octagon-reporting 0.1.6, migration 0109). 2026 to date: 90 of
92 placements matched, 2 overdue, 39 unmatched Won deals (£164,864).

---

## The daily action queue: ranked calls in Slack, drafting in your own Claude

**Decision.** An 08:30 Slack DM per consultant lists up to 10 ranked calls (`action_queue()`, migration
0115; thresholds in [Metrics](wiki/Metrics-and-Definitions.md#daily-action-queue)). The DM carries no
drafts: "prep my queue" in the consultant's own Claude writes the prep notes, chase and booking emails,
Booleans and InMails. Each call has a Done button (`slack-actions`, 0118) that previews the note it
will log in RecruitCRM, writes it as the consultant only on Confirm, and hides the item for a set
number of days by kind. New jobs and Friday Push & Tell joined the queue in 0121 (client
rejections too, until 0126 took them out on 28/10/2026)
as triggers for drafts (priority 7), on the same rule: nothing is sent until the consultant approves.

**Why.** The 13/10/2026 rule of no server-side AI: candidate and client data stays inside each
person's own Claude. Older offers (over 21 days) and requests (over 14 days) go to one clean-up line,
so stale stages don't crowd out today's calls (0116).

**Status:** **Live 26/10/2026** for a pilot of four: Will Drake, Keelan Riley, Adam Barnett and
Bhavesh Patel (`action_queue_pilot`), shadow mode off.

---

## Weekly plan worked back from billing

**Decision.** Each person's weekly CVs, interview requests and interviews are worked back from their
quarterly billing target at a run-rate over 13 weeks, using their own 6-month ratios blended towards
the firm's when the sample is small, and never below the flat minimums (`weekly_plan()`, 0119).
Nobody without a billing target gets a plan from billing; they get the flat minimums.

**Why.** Catch-up to the quarter end would only spike late, and a CV sent in December rarely bills by
31/12. For the one consultant with no target, the firm median gave 26 CVs a week: about 13 times their
own rate.

**Status:** **Live 26/10/2026** (0119, 0120). Monday plan line in the DM; Friday actuals against plan
in the end-of-week email.

---

## Manager exceptions: only real outliers

**Decision.** `team_exceptions()` (0121) shows managers only the people with something to act on,
as a Monday DM to `manager_exceptions_emails` and through `/exceptions`. Off plan means below half the
plan on **both** CVs and interviews in the last full week (0122); backlog means 25+ calls queued or 3+
stages out of date; ratios must fall more than 30% with enough volume.

**Why.** At 70% of plan and 10+ calls every consultant was flagged, and at half the plan on any one
metric six of eight were. A list that names everyone isn't a list of exceptions.

**Status:** **Live 26/10/2026.** The first Monday DM is due 02/11/2026.

---

## Slack: the admin bot carries sync alerts only

**Decision.** The analytics-admin bot (`alert_webhook_url`) posts sync and cron alerts only. The
briefs post from the "(Claude) - Team Briefs" app to #briefs (`digest_webhook_url`), and
the DMs use that app's bot token (0114).

**Why.** Decided 26/10/2026, when the briefs moved to their own channel: the admin bot should only
ever carry alerts, so nothing else can bury one. Since 0114 nothing else holds its URL.

**Status:** **Live 26/10/2026.**

---

## RecruitCRM is changed through the connector, never a browser

**Decision.** Claude changes RecruitCRM only through Octagon tools. If no tool can make a change, it
says so and gives the manual step. It never opens a browser panel to do it. The connector's
instructions carry the rule, and `update_job` and `add_note` gained the job order form so the case
that triggered it is covered (3.77.0).

**Why.** On 26/10/2026, asked to fill in a job order form, Claude opened RecruitCRM in a browser panel.
Signing in there logged the user out of RecruitCRM.

**Status:** **Live 26/10/2026.**

---

## Internal Job Descriptions are read from the file

**Decision.** `job_spec` reads the Internal Job Description file attached to a job (a job custom
field, which `files_list` does not see) and returns its text: PDF, Word, old .doc and Excel. A broken
link says so and asks for a re-upload. Scanned PDFs and files over 10 MB are not read; Claude says to
open them in RecruitCRM.

**Why.** "Add the Internal JD to the job description" stopped working because the file lives in a
custom field, not the job's files. `internal_jd_check` across the 113 open-job Internal JDs set what
to build.

**Status:** **Live 26/10/2026** (octagon-mcp 3.75.4 and 3.75.5).

---

## The Octagon Coach: rule-based nudges from a separate Slack app

**Decision.** A separate Slack app, Octagon Coach, DMs each pilot consultant at 12:30 (the main check:
today so far, the afternoon's top 3, one command to try), 16:45 (admin before home time; Fridays add the
week) and Monday 08:45 (the week ahead, billing pace). `coach_nudges()` picks each nudge by rule from
their own numbers, and each one names the command or prompt to use in their own Claude. It sends at most
3 suggestions, skips anything already done today, goes gentle on Mondays and Tuesdays, and has Pause for
today and Mute buttons. It started in shadow mode.

**Why.** The Team Briefs 1:1 DMs were well received, and a coach that points at the right command at the
right time is where usage turns into habit. It is rule-based to keep the 13/10/2026 rule of no AI on the
server, and a separate app so it can be muted, measured and switched off without touching the queue or
the briefs. An AI-written coach in each person's own Claude (Slack connector plus a scheduled task) was
considered and set aside for now. Redrawing the team briefs (Block Kit, then image cards) was tried and
dropped on 28/10/2026; the briefs are unchanged.

**Status:** **Live in shadow mode 28/10/2026** (0129, `coach-dm`, `coach-actions`). The pilots get it
once `coach_shadow` is set to `false`.

