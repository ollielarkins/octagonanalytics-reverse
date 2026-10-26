# Metrics and definitions

The canonical meaning of every figure. If a number appears in two places it comes from the same
view or RPC — there is no second implementation.

## Attribution — who gets the credit

| Metric family | Attributed to |
|---|---|
| Funnel activity (CV sent → placed) | **Whoever moved the stage**, falling back to the job owner |
| Desk views (cold jobs, stalled, time to fill, placements, rejections) | The **job owner** |
| Calls | The **caller** |
| Billing / fees | The **deal owner** |

These genuinely differ. A CV sent by one person against another's role counts to the person who sent
it (0066, 02/09/2026): checked against RecruitCRM's January report, actor attribution matched 20 of 27
per-consultant figures, where job owner scattered and credited people with activity on jobs they
inherited later. Leavers keep their activity, tagged "left".

## The funnel

Source: `candidate_stage_events`, and nothing else. Deal stages and any other activity table are
never blended in — mixing sources is how the same metric ends up with three answers.

Canonical order:

**Shortlist → CV Sent → Interview Request → 1st Interview → 2nd Interview → 3rd Interview → Offered → Placed**

Shortlist is partially adopted, so it is not a valid top-of-funnel denominator. See
[Data Caveats](Data-Caveats).

A "placement" for all funnel, consultant and team reporting is the count of `placed` events — not a
row in the `placements` table, which is a join record carrying no money.

## Rejections

- `rejected_by_client` — the client turned the candidate down
- `rejected_by_consultant` — we screened them out ourselves
- `client_rejection_rate_pct` = rejected_by_client ÷ cv_sent, as a percentage to 1dp

2026 to date: 2,194 CVs sent, 1,179 client rejections (53.7%), 4,786 screened out internally.

A high rate is a prompt, not a verdict. It can mean the wrong candidates are going out, the role was
briefed badly, or the client is simply hard to please. Look at the client breakdown before the
consultant breakdown.

## Money

**The fee is the Won deal value.** There is no separate fee record — `deals.deal_value` has always
been the fee. Won deals have a median of £6,432 and 713 of 862 fall between £2,000 and £30,000.

| Term | Definition |
|---|---|
| **Billing** | `sum(deal_value)` where stage = Won, bucketed by `close_date` |
| **Pipeline value** | `sum(deal_value)` over open deals (not Won or Lost) — the forward indicator |
| **Forecast** | `sum(jobs.forecast_fee)` across open roles — £1,546,032 currently |
| **Fee components** | `annual_salary` × `fee_percentage` ÷ 100 on the deal |

The components reconcile: 629 of 722 deals holding both satisfy `deal_value = salary × pct ÷ 100`
to within £1.

2026 to date: 90 Won deals, £610,488, median fee £6,120, fee percentage median **18.0%** (quartiles
16–20%), salary placed median £35,500 (quartiles £30,000–£55,000).

**Always quote the median fee percentage.** Two deals carry a mistyped percentage — one reads 7000 —
which drags the mean to 34.4% against a true median of 18.0%. `fee_analysis` excludes values above
100 from its percentage stats and reports how many it dropped.

**A placement is worth one Won deal** (0109, 26/10/2026). Deals carry a job but no candidate, so
`placement_deal_match()` pairs each placement with at most one Won deal on the same job, and each Won
deal with at most one placement: the candidate's name in the deal name first, then the deal created
nearest the placement date. `match_basis` says which rule made the pair. Any other Won deal on the job
is a separate fee and shows as unmatched, never summed into a placement. Billing itself is unchanged.

Note the "Placed" deal stage carries no fee. Billing happens when a deal is moved to Won and the
value entered — not when a candidate is marked Placed.

## Weekly KPI targets

Per recruiter, week running Monday to Sunday:

| Metric | Target |
|---|---|
| CV sends | 10 |
| Interview requests | 5 |
| Interviews (1st) | 4 |
| BD calls | 5 |
| Client calls | 5 |

Placements are reported but carry no weekly target — billing is quarterly.

BD and client calls only count *categorised* Devyce calls, so they undercount. `call_tagging_rates()`
gives each person's weekly tagging rate, shown in the Day End brief beside their untagged count. `bd_calls` is the
"Contact - Prospect (BD)" category; `client_calls` is "Contact - Client" plus "Contact - Client Info".

## Quarterly billing targets

Set per recruiter, not uniform — currently ranging £30,000 to £45,000 across 7 people. Anyone
without a loaded target shows as TBC rather than being assumed.

## Weekly plan from billing

`weekly_plan()` (0119, 26/10/2026) works each person's week back from their quarterly target:

- **Run-rate, not catch-up.** The quarter's target is spread over 13 weeks. The quarter's position is
  shown alongside, but the plan does not spike late to close a gap.
- **Their own ratios, blended when the sample is small.** Over the last 6 months, each ratio is shrunk
  towards the firm's: (own + k × firm rate) ÷ (own volume + k), with k = 40 CVs, 40 CVs, 20 first
  interviews and 5 offers. Median fee from their Won deals in 12 months, or the firm's if they have
  fewer than 4.
- **Never below the flat minimums** (10 CVs, 5 interview requests, 4 interviews). When their target
  needs fewer, the Monday line says "Your target needs fewer, so this is the minimum".
- **No target, no plan from billing**: just the flat minimums, and the DM says so.

Monday: a plan line in the 08:30 DM. Friday: actuals against plan in the end-of-week email.

## Daily action queue

`action_queue()` (0115 to 0121) ranks each person's calls for the 08:30 DM and `/queue`. At most 10
items; the totals say how many there were before the caps.

| Rank | Trigger | Cap |
|---|---|---|
| 1 | Offer out with no answer, 3+ days (up to 21) | all |
| 2 | Interview on the next working day: prep call | all |
| 3 | Interview held, nothing logged: feedback call | all |
| 3 | New job in the last 3 days: kick it off | all |
| 3 | Rejected by the client in the last 4 days, no note since: update the candidate | all |
| 4 | Interview request unbooked, 2+ days (up to 14) | 3 |
| 5 | CV sent, no response, 5+ working days | 3 |
| 6 | Cold job, 7+ days without activity | 2 |
| 7 | Behind on BD calls this week (Tuesday to Friday, tagged BD calls only) | 1 |

Older offers and requests go to one "clean up these stages" line instead. Closing lines that are not
calls: the Monday plan, Monday client visits, and Push & Tell on Fridays. Done in Slack logs a note
in RecruitCRM on confirm and hides the item for a set number of days by kind.

## Client visits

A client visit is a RecruitCRM meeting typed **Client Meeting**. The minimum is 2 per consultant per
quarter. `client_visits()` counts done and booked, lists untyped meetings separately (they cannot
count until typed), and suggests up to five clients to visit: live A and B grade jobs, biggest
billers, no recent visit, low CV→interview or slow feedback, warm prospects.

## Manager exceptions

`team_exceptions()` lists only people with something to act on. Managers only; Dale Barnett is left
out (`exceptions_exclude_ids`).

| Exception | Rule |
|---|---|
| Off plan | Last full week below half their plan on **both** CVs and interviews (0122) |
| Backlog | 25+ calls on their queue today, or 3+ stages out of date |
| Ratios falling | CV→interview or interview→offer over the last 8 weeks more than 30% below the previous 6 months, with 20+ CVs (or 10+ interviews) in the 8 weeks |
| Client visits | Done plus booked below the pace for 2 per quarter, from week 4 |

## Attention thresholds

Used by `my_day` and `stalled_report`, on **open roles only**:

- **Aging offer** — offer out between 5 and 60 days with no movement
- **Stalled** — at an active stage (CV Sent through Offered) with no movement for 10 to 60 days
- **Cold role** — open role with no candidate activity for 14 days

The 60-day ceiling is deliberate. Beyond that a candidate is abandoned, not stalled, and including
them produced a list of 1,517 items that nobody could act on.

## Closure reasons

Recorded when a job is closed (closed, cancelled, on hold) or a deal is moved to Lost or Declined.
Optional, picked from a configured list in `closure_reasons`, with free text alongside. Any other
deal stage move takes free text only.

`closure_reasons_report` counts them by reason over a window. Two limits on reading it:

- It counts **only what was recorded through Claude**. A job closed directly in RecruitCRM with a
  reason typed into their UI is not in `closure_reason_log`.
- Because it is optional, a reason's absence means "nobody said", not "no reason". Do not compute a
  percentage over closures that have no reason recorded.

## Deleted records

Hidden from operational surfaces, kept in historical counts — see
[Data Caveats](Data-Caveats). Deleting a candidate does not change last quarter's CV sends.

## Conventions

- Money: £ with thousands separators — £45,000. Pence only when exact.
- Rates: one decimal place, naming the ratio — "CV→placed 2.4%".
- Dates: DD/MM/YYYY.
- Default window: 2026 year to date, end exclusive.
- Tables: highest first.

## Previously "not tracked" — all of it is tracked

Every metric this project documented as unmeasurable turned out to be recorded in RecruitCRM. The
platform simply never read it. Corrected 10/08/2026.

| Metric | Where it lives | 2026 to date |
|---|---|---|
| **Leads** | A `Lead` **note type** | 422 |
| **Internal interviews** | A `Candidate - Internal Interview` **note type** | 255 |
| **Job order form complete** | A `Job Order Form Complete` **note type** | 92 |
| **Pitched candidates** | RecruitCRM's pitch feature — its own pipeline, stages and history | in use |
| **Client visits** | Meetings typed Client Meeting, mirrored daily since 0118 | see [Client visits](#client-visits) |

Notes are now mirrored, so the three note-based figures are countable by consultant and period —
ask for them, or call `notes_kpi`. Pitches are read live via `pitch_history`; meetings are mirrored
(this quarter and last) and also read live via `activity_report` and `schedule`.

Two caveats that matter when quoting these:

- **They count what was logged, not what happened.** A lead nobody wrote a note about does not
  exist here. Low numbers may mean low activity or low recording — the same problem as Devyce call
  tagging.
- **There is also a `Job Lead` deal stage** with zero deals in it. If anyone starts using it, leads
  will exist in two places and will need reconciling before either figure is quoted.

---

**See also:** [Data Caveats](Data-Caveats) for where these definitions meet messy data · [Tools Reference](Tools-Reference) for which tool reports what · [Architecture](Architecture) for where the numbers come from · [Commands](Commands)
