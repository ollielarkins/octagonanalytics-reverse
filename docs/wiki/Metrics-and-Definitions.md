# Metrics and definitions

The canonical meaning of every figure. If a number appears in two places it comes from the same
view or RPC — there is no second implementation. Anything not defined here isn't tracked.

## Attribution — who gets the credit

| Metric family | Attributed to |
|---|---|
| Funnel (CV sent → placed) | The **job owner** |
| Calls | The **caller** |
| Billing / fees | The **deal owner** |

These genuinely differ. A CV sent by one person against another's role counts to the role owner.

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

BD and client calls only count *categorised* Devyce calls, so they undercount. `bd_calls` is the
"Contact - Prospect (BD)" category; `client_calls` is "Contact - Client" plus "Contact - Client Info".

## Quarterly billing targets

Set per recruiter, not uniform — currently ranging £30,000 to £45,000 across 7 people. Anyone
without a loaded target shows as TBC rather than being assumed.

## Attention thresholds

Used by `my_day` and `stalled_report`, on **open roles only**:

- **Aging offer** — offer out between 5 and 60 days with no movement
- **Stalled** — at an active stage (CV Sent through Offered) with no movement for 10 to 60 days
- **Cold role** — open role with no candidate activity for 14 days

The 60-day ceiling is deliberate. Beyond that a candidate is abandoned, not stalled, and including
them produced a list of 1,517 items that nobody could act on.

## Conventions

- Money: £ with thousands separators — £45,000. Pence only when exact.
- Rates: one decimal place, naming the ratio — "CV→placed 2.4%".
- Dates: DD/MM/YYYY.
- Default window: 2026 year to date, end exclusive.
- Tables: highest first.

## Not tracked

Leads, pitched candidates, internal interviews, client visits. RecruitCRM has no field for any of
them. Nothing can report them and nothing should try. See [Data Caveats](Data-Caveats) for how they
could be added.
