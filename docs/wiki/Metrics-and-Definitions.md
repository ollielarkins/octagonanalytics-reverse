# Metrics and Definitions

For anyone quoting an Octagon number: what each figure counts, who gets the credit, and which
function produces it.

*Last reviewed 04/11/2026.*

**On this page:** [Attribution](#attribution) · [The funnel](#the-funnel) · [Weekly KPIs](#weekly-kpis) ·
[Calls](#calls) · [Money](#money) · [Weekly plan from billing](#weekly-plan-from-billing) ·
[Daily action queue](#daily-action-queue) · [Coach](#coach) · [Client visits](#client-visits) ·
[Manager exceptions](#manager-exceptions) · [Desk and client lists](#desk-and-client-lists) ·
[Logged activity](#logged-activity) · [Conventions](#conventions)

Every figure comes from one SQL function or view. If a number appears in two places, both read the
same function: there is no second implementation.

## Attribution

| Metric family | Credited to | Why |
|---|---|---|
| Funnel activity (CV Sent to Placed) | The **actor who made the stage move** | Checked against RecruitCRM's January report, actor matched 20 of 27 per-consultant figures; job owner credited people with work on jobs they inherited later (0066) |
| Desk views (cold jobs, stalled, time to fill, rejections, silver medallists) | The **job owner** | The desk is whoever owns the role now |
| Calls | The **caller** | |
| Billing, fees, aftercare | The **deal owner** | |

Leavers keep their activity and stay in totals, tagged "left". Nothing is reattributed.

## The funnel

Source: `candidate_stage_events` (RecruitCRM's hiring-stage history) and nothing else. Deal stages
and other activity tables are never blended in.

**CV Sent → Interview Request → 1st Interview → 2nd Interview → 3rd Interview → Offered → Placed**

| Term | Definition |
|---|---|
| Stage count | Candidate-job pairs reaching the stage, counted **once, at the last time they entered it**, credited to whoever made that move (`funnel_report`, `kpis_report`) |
| Conversion rate | A share of CVs sent, to 1 dp, naming the ratio: CV→interview request, CV→placed |
| Placement | A `placed` stage event. Not a row in `placements` (empty; see [Data Caveats](Data-Caveats#placements-carry-no-money)) and not a deal |
| `rejected_by_client` | The client turned the candidate down |
| `rejected_by_consultant` | We screened them out ourselves (includes declined offers) |
| Client rejection rate | `rejected_by_client` ÷ CVs sent |

Shortlist exists as a stage but is only partly used, so it is never a denominator. Parity with
RecruitCRM's own report is ~0.4%, not exact: see [Data Caveats](Data-Caveats#funnel-parity-with-recruitcrms-report).

A high client rejection rate is a prompt, not a verdict: wrong candidates, a poor brief or a hard
client. Look at the client breakdown before the consultant breakdown.

## Weekly KPIs

Per recruiter, Monday to Sunday (`kpis_report`, targets from `weekly_targets`):

| Metric | Weekly target | Counts |
|---|---|---|
| CV sends | 10 | `cv_sent` stage moves this week, by the actor |
| Interview requests | 5 | `interview_request` stage moves |
| Interviews | 4 | `first_interview` stage moves |
| BD calls | 5 | Calls tagged `Contact - Prospect (BD)`, by the caller |
| Client calls | 5 | Calls tagged `Contact - Client` or `Contact - Client Info` |

Placements are reported with no weekly target: billing is quarterly. Early-week gaps are expected.
Quarterly billing targets are set per recruiter; anyone without one shows as TBC.

## Calls

All calls are Devyce call logs mirrored from RecruitCRM (`call_activity`).

| Term | Definition |
|---|---|
| Call | One call log, attributed to the caller. Connected = duration above 0 |
| Tagged call | A call with a category (`custom_call_type`). Only tagged calls count toward BD and client targets |
| Tagging rate | `call_tagging_rates()`: share of calls of 30 seconds or more that are tagged, per active consultant, for a UK week against the week before. In the Monday Week Ahead brief |
| Untagged count | Today's untagged calls of 30 seconds or more, contact calls first, in the 17:30 Day End brief (0112) |
| `likely_untagged` | **New, 0148.** Untagged calls this week of 30 seconds or more, logged against a client contact, that probably were BD or client calls. In `kpis_report` (per metric) and `call_activity_report` (`untagged_likely_bd`, `untagged_likely_client`). Shown beside the tagged count, **never added to it** |

`likely_call_type()` decides the probable type of an untagged call to a contact, first rule that
applies:

1. How that contact's earlier calls were most often tagged (voicemail ignored).
2. The company's status: Client → client call; Prospect, Engaged or Passive → BD call.
3. A job at the company created in the last 18 months → client call.
4. Otherwise → BD call.

It agreed with recruiters' own tags on 84% of 1,654 tagged calls. It is a guess to prompt tagging
(the coach's 16:45 one-press tag uses it), not a count.

> [!IMPORTANT]
> BD and client call figures undercount until calls are tagged. Quote them with the person's
> tagging rate or `likely_untagged` beside them. See [Data Caveats](Data-Caveats#call-categorisation).

## Money

**The fee is the Won deal value.** There is no separate fee record. The Placed deal stage carries no
fee: billing happens when a deal is moved to Won and the value entered.

| Term | Definition |
|---|---|
| **Billing** | `sum(deal_value)` on Won deals by **close date**, by deal owner (`billing_report`). The quarter runs start inclusive to end exclusive, in UK time, so a close date later in the quarter counts. Split into **Won to date** (closed on or before today) and **Won later this quarter**. Deleted deals excluded |
| **Pipeline** | `sum(deal_value)` on deals at Open, CV Sent, Interview Request, 1st, 2nd, 3rd Interview or Offered, not deleted. The forward indicator. Declined and Placed are not pipeline. Same figure on the dashboard and in billing |
| **Forecast** | `sum(jobs.forecast_fee)` across open roles |
| **Fee components** | `annual_salary` × `fee_percentage` ÷ 100 on the deal; most Won deals holding both reconcile to within £1 |
| **Fee percentage** | Always quote the **median** (18.0% on Won deals). `fee_analysis` drops values above 100 from its percentage stats and says how many |
| **Placement fee** | `placements_with_fees` pairs each placement with **at most one** Won deal on the same job (0109): candidate name in the deal name first, then the deal created nearest the placement date. `match_basis` says which. Other Won deals on the job are separate fees, listed as unmatched, never summed in |
| **Unbilled placement** | A placement with no Won deal on its job. The coach flags one after 14 days |

There is no invoice data: RecruitCRM's invoices are not mirrored. See
[Data Caveats](Data-Caveats#no-invoices).

## Weekly plan from billing

`weekly_plan()` (0119) works each person's week back from their quarterly billing target.

- **Run-rate, not catch-up.** The target is spread over 13 weeks; the quarter's position is shown
  alongside, but the plan does not spike late.
- **Own ratios, blended when the sample is small:** (own + k × firm rate) ÷ (own volume + k), with
  k = 40 CVs, 40 CVs, 20 first interviews and 5 offers, over the last 6 months. Median fee from their
  Won deals in 12 months, or the firm's with fewer than 4.
- **Never below the flat minimums** (10 CVs, 5 interview requests, 4 interviews).
- **No billing target, no plan from billing:** just the minimums, and the DM says so.

Monday: a plan line in the 08:30 DM. Friday: actuals against plan in the end-of-week email.

## Daily action queue

`action_queue()` ranks each person's calls for the 08:30 DM and `/queue`. At most 10 items; the
totals give the count before the caps.

| Rank | Trigger | Cap |
|---|---|---|
| 1 | Offer out with no answer, 3 to 21 days | all |
| 2 | Interview on the next working day: prep call | all |
| 3 | Interview held, nothing logged: feedback call | all |
| 3 | New job in the last 3 days: kick it off | all |
| 4 | Interview request unbooked, 2 to 14 days | 3 |
| 5 | CV sent, no response, 5+ working days | 3 |
| 6 | Cold job, 7+ days without activity | 2 |
| 7 | Behind on BD calls this week (Tuesday to Friday, tagged BD calls only) | 1 |

Closing lines that are not calls: one "clean up these stages" line for older offers and requests,
untyped meetings (Mondays and Thursdays), client visits (Mondays, while under 2 this quarter), the
Monday plan, and Push & Tell on Fridays. Client rejections are not prompted (0126). Done in Slack
logs a note in RecruitCRM and hides the item for a set number of days by kind.

## Coach

The Octagon Coach DMs at 12:30, 16:45 and Monday 08:45 (`coach_nudges()`, 0129, 0147, 0148). Its
suggestions come from the same data as the queue, diary and plan.

| Term | Definition |
|---|---|
| Today's share | The weekly plan ÷ 5, rounded up: the day's CVs, requests and interviews "on plan" |
| Pace | Plan × days so far ÷ 5 (half of today at midday). Ahead of pace with nothing urgent = one line, no stats |
| No repeats | A kind of suggestion made on the person's last coached day is skipped today. Offers, interview prep and call tagging are exempt |
| Skipped day | Midday and wrap are not sent on a day with nothing logged: no call, stage move, queue item done or Octagon use (0148) |
| Away | "Away? Pick your last day off" pauses the coach until that date (0148). RecruitCRM's diary holds no leave |
| `coach_effect()` | **New, 0147.** For each suggestion over the last 28 days (default), whether it was **acted on within 3 hours**: Done or a tag press; the suggested tool used successfully; for a named suggestion, a call to that candidate or company or a stage move on that candidate; for a match suggestion, any CV sent; for a tagging suggestion, a call type set. By kind and by person, split live and shadow |

Shadow rows were never seen by the recruiter, so they are the baseline. "Acted on" is a signal, not
proof: some of it would have happened anyway.

## Client visits

A client visit is a RecruitCRM meeting typed **Client Meeting**. The minimum is 2 per consultant per
quarter. `client_visits()` counts visits done and booked this quarter, lists untyped meetings
separately (they cannot count until typed with `meeting_review`), and suggests up to five clients
to visit, ranked by live A and B grade jobs, Won fees in the last 12 months, and no visit in 90 days.

## Manager exceptions

`team_exceptions()` lists only people with something to act on. Managers only; the Monday DM goes
to the people in `manager_exceptions_emails`.

| Exception | Rule |
|---|---|
| Off plan | Last full week below half their plan on **both** CVs and interviews (0122) |
| Backlog | 25+ calls on their queue today, or 3+ stages out of date |
| Ratios falling | CV→interview or interview→offer over the last 8 weeks more than 30% below the previous 6 months, with 20+ CVs (or 10+ interviews) in the 8 weeks |
| Client visits | Done plus booked below the pace for 2 per quarter, from week 4 |

## Desk and client lists

| List | Function | Definition |
|---|---|---|
| Aging offer | `my_day`, `stalled_report` | Open role, offer out 5 to 60 days with no movement |
| Stalled | `my_day`, `stalled_report` | Open role, at CV Sent to Offered, no movement for 10 to 60 days |
| Cold role | `my_day` | Open role with no candidate activity for 14 days |
| Silver medallists | `silver_medallists` (0137) | Reached 2nd, 3rd interview or Offered, then rejected (client or consultant). One row per candidate at their closest miss. Leaves out anyone placed since, back in play on an Open job, off limit, or deleted. Suggested roles are Open jobs with the most similar title, for the consultant to judge |
| Lapsed clients | `lapsed_clients` (0139, 0146) | Companies we have placed with, with no Open or On Hold job and no new job in 6 months (default). Last touch = latest call or note on the company or any of its contacts, or a visit. Blocklisted and Do not contact companies left out |
| Aftercare | `aftercare` (0140) | Check-ins on placements from Won deals with a start date: before start, week 1 (+7 days), month 1 (+30), month 3 (+91). Listed from 7 days before due to 14 days after. `contacted_since` marks a call or note since the window opened; nothing is marked done automatically. No rebate dates (terms not recorded) |
| Data hygiene | `data_hygiene` (0141 to 0143) | Record gaps that make figures wrong: Won deals with no fee %, no salary, salary entered in thousands, no value, no start date or no job; placed with no Won deal; Offered with no deal; live jobs owned by a leaver; jobs with no client; untagged calls of 30s+ in 7 days. Each with the records and the fix |

The 60-day ceiling on aging and stalled is deliberate: beyond it a candidate is abandoned, not
stalled, and including them gave a list of 1,517 items nobody could act on.

## Logged activity

These count **what was logged**, not what happened. Low numbers can mean low activity or low
recording, like call tagging.

| Metric | Where it lives | Read by |
|---|---|---|
| Leads | `Lead` note type | `notes_kpi` |
| Internal interviews | `Candidate - Internal Interview` note type | `notes_kpi` |
| Job order forms | `Job Order Form Complete` note type | `notes_kpi` |
| Pitches | RecruitCRM's pitch feature | `pitch_history` (live) |
| Client visits | Meetings typed Client Meeting | `client_visits` |

`notes_kpi` counts notes by type, attributed to the note author. A `Job Lead` deal stage also exists
with no deals in it; if anyone starts using it, leads will live in two places.

**Closure reasons** (`closure_reasons_report`) count only reasons recorded through Claude when a job
is closed or a deal moved to Lost or Declined. They are optional, so an absent reason means "nobody
said": never take a percentage over closures with no reason.

**Deleted records** are hidden from operational views and kept in historical counts. Deleting a
candidate does not change last quarter's CV sends.

## Conventions

| | |
|---|---|
| Money | £ with separators: £45,000. Pence only when exact |
| Rates | 1 dp, naming the ratio: CV→placed 2.4% |
| Dates | DD/MM/YYYY |
| Default window | 2026 year to date, end exclusive |
| Tables | Highest first |

---

**Related:** [Data Caveats](Data-Caveats) · [Tools Reference](Tools-Reference) · [Architecture](Architecture) · [Commands](Commands)
