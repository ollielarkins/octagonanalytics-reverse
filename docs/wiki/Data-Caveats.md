# Data caveats

Where the numbers are soft, why, and what it would take to fix. Read this before quoting anything
outside the building.

Everything here is measured, not estimated. Figures as at 10/08/2026.

---

## Call categorisation — 26.6%

**The big one.** BD and client call KPIs key off `custom_call_type`, and only 1,327 of 4,995 Devyce
calls are tagged.

| Consultant | Calls since 01/07 | Tagged | Rate |
|---|---|---|---|
| Steve Bernat | 55 | 26 | 47.3% |
| Tarah Williams | 158 | 67 | 42.4% |
| Scott Newcomen | 209 | 83 | 39.7% |
| Bhavesh Patel | 145 | 46 | 31.7% |
| Keelan Riley | 303 | 91 | 30.0% |
| Adam Barnett | 240 | 72 | 30.0% |
| Jennifer Seress | 345 | 80 | 23.2% |
| Georgia Cook | 397 | 71 | 17.9% |
| Chloe Edwards | 273 | 44 | 16.1% |

Note the shape: **the busiest desks tag least**. Georgia and Chloe make the most calls and record
the least about them, so their BD and client KPIs look worst precisely because they're busiest.
Never coach off those two numbers without checking the tagging rate first.

The recruiter dashboard now shows each person their own rate beside the KPI. The fix is behavioural,
not technical.

---

## Shortlist is partially adopted

1,595 shortlist events against 3,361 CV sends. Some of the desk uses the stage, some skips straight
to CV Sent. It appears first in the funnel but a shortlist→CV rate can exceed 100%, which means
nothing. Don't use it as a denominator.

---

## Two deals with a mistyped fee percentage

One reads 7000. They drag the mean fee percentage to 34.4% against a true median of 18.0%.
`fee_analysis` excludes values above 100 and reports the count excluded. **Quote the median.**

These are data-entry errors in RecruitCRM and should be corrected at source.

---

## 64 ghost deals

64 rows carry a null `recruitcrm_id`. The reconcile skips nulls and the backfill matches on that
key, so they are unreachable by every sync path. All were created in one instant on 08/07/2026 — a
one-off import.

| Stage | Deals | Value |
|---|---|---|
| CV Sent | 51 | £0 |
| Interview Request | 9 | £0 |
| Placed | 4 | £0 |

**Billing is unaffected** — none are Won, all are £0. They inflate deal *counts* on the pipeline
table, and they are the entire "Placed — 4 deals, £0" row. Pending deletion.

---

## Candidate counts mean two different things

- **Candidates in pipeline: 6,133** — have moved through at least one hiring stage
- **Candidates on CRM: 16,629** — every live candidate record

The dashboard showed the first under the label "Candidates" until 10/08/2026, understating the
database by ~10,500. Both are now shown separately.

---

## Skills coverage — 73%

`match_candidates` only considers candidates with skill text populated: 12,253 of 16,629. A
candidate missing from a shortlist may simply have no skills on file.

---

## ~40% of jobs had no client — fixed 10/08/2026

Worth knowing because it invalidates earlier analysis. Client attribution was missing on 2,410 of
5,975 jobs, and it was documented for months as "archived companies in RecruitCRM".

That was wrong. The sync built its slug→client lookup with an unbounded query, PostgREST caps those
at 1,000 rows, and `clients` holds ~4,600 — so three quarters of companies were missing from the map
and any job outside the first page had its client link written as null. Every sync that touched a
job re-orphaned it.

Now 9 of 5,975 (0.2%), none of them open. `client_report` covers 99.8% of jobs.

**Any client or account analysis produced before 10/08/2026 was computed on ~60% of the data and
should be re-run.**

---

## Pre-2026 history is sparse

RecruitCRM's hiring-stage history thins out badly before 2026. Reporting defaults to a 2026-onward
window for that reason. Comparisons across that boundary aren't like-for-like.

---

## Not tracked at all

Leads, pitched candidates, internal interviews, client visits. No field exists for them.

They aren't hard to add, and none of it needs new tables — the sync already mirrors every
extensibility point RecruitCRM offers:

| Metric | Where it should live | Work needed |
|---|---|---|
| Internal interview | A hiring-pipeline stage | One row in `stage_lookup` |
| Pitched candidates | A hiring stage, or a Devyce call category | One row, or one label in the KPI mapping |
| Client visits | A Devyce call category | One label in the KPI mapping |
| Leads | A `Lead` company status | Flows into `bd_report` automatically |

Precedent: someone added a **Shortlist** stage to the pipeline and it has been recording silently
since 13/02/2025 — 1,595 events — with no engineering work at all.

Two caveats. Each only counts from the day it's switched on, with no history. And the call-category
route inherits the 26.6% tagging problem, while the hiring-stage route doesn't — moving a candidate
*is* the work, rather than admin done afterwards. Prefer stages where there's a choice.

---

## The placements table is empty, and always will be

`GET /v1/placements` exists, but a placement record carries no money at all — no fee, no salary, and
`custom_fields` came back empty across a full page. It's a join record: candidate ↔ job ↔ company ↔
deal. The fee lives on the deal. If placements are ever synced it should be for `deal_slugs`, which
is the only route to a per-placement fee.

---

## Adoption

17 tool calls in the last 30 days from two identities. Nine of eleven recruiter tokens have never
been used. `audit_log` is empty — no write has ever been made.

Any conclusion drawn from usage data is drawn from almost no usage.
