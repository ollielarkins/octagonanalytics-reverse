# Data caveats

Where the numbers are soft, why, and what it would take to fix. Read this before quoting anything
outside the building.

Everything here is measured, not estimated. Figures as at 10/08/2026.

---

## Call categorisation

> [!CAUTION]
> **This is the biggest soft spot in the platform, and it is getting worse.** BD and client call
> KPIs count only *categorised* Devyce calls. Categorisation has fallen from 26% to 9% since May.

Only 1,850 of 10,331 calls carry a `custom_call_type` — 17.9% overall, and the trend is the story:

| Month | Calls | Tagged | Rate |
|---|---|---|---|
| May 2026 | 727 | 189 | 26.0% |
| June | 2,029 | 530 | 26.1% |
| July | 2,066 | 484 | 23.4% |
| August | 3,625 | 476 | 13.1% |
| September (to 15th) | 1,882 | 169 | **9.0%** |

Call volume nearly doubled from July to August while tagging halved. Weekly targets are 5 BD and 5
client calls; at a 9% tag rate a recruiter making ten real BD calls records about one. **The KPI is
now roughly a tenth of reality, and falling.**

Per consultant since 01/08/2026:

| Consultant | Calls | Tagged | Rate |
|---|---|---|---|
| Bhavesh Patel | 128 | 53 | 41.4% |
| Adam Barnett | 388 | 72 | 18.6% |
| Scott Newcomen | 605 | 112 | 18.5% |
| Tarah Williams | 385 | 67 | 17.4% |
| Keelan Riley | 633 | 101 | 16.0% |
| Will Drake | 403 | 62 | 15.4% |
| Steve Bernat | 145 | 18 | 12.4% |
| Jennifer Seress | 822 | 73 | 8.9% |
| Dale Barnett | 129 | 10 | 7.8% |
| Georgia Cook | 1,449 | 75 | 5.2% |
| Chloe Edwards | 361 | 2 | **0.6%** |
| Lewis Hay | 59 | 0 | **0%** |

The shape from the original analysis still holds — **the busiest desks tag least**. Georgia makes the
most calls of anyone and tags one in twenty. Chloe has tagged twice since August. Never coach off a
BD or client call number without checking the tagging rate beside it.

Only four categories carry real volume: Contact – Prospect (BD) 800, Contact – Client 540,
Candidate – Job Pitch/Qualifying 238, Interview Feedback 160. Everything else is negligible.

The recruiter dashboard shows each person their own rate beside the KPI. The fix is behavioural, not
technical — but at 9% the metric is arguably not worth reporting until tagging recovers.

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

## Deleted records are hidden from operations, not from history

Ratified 15/09/2026. A deleted candidate, job, client or deal is tombstoned with `deleted_at` and
disappears from **operational** surfaces — search, matching, the live deal pipeline, chase lists. It
stays in **historical** counts: the funnel, activity, rankings and revenue.

The reason is that deleting a candidate must not silently drop their CV sends out of last quarter's
numbers. The work happened. Retroactively rewriting history would also move parity against
RecruitCRM's own report, which is measured against fixed periods. The same principle already applies
to leavers: credited to whoever did the work, never reattributed.

Before 15/09/2026 the tombstone hid nothing at all — `delete_record` set `deleted_at`, but no read
path checked it, so a deleted candidate still came back in search and could still be matched to a job
and pitched to a client.

Deletion is detected two ways: instantly via the `*.deleted` webhooks, and by reconcile page-walks as
the backstop. A deletion made while a webhook delivery fails is caught within the hour.

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

## The metrics we said weren't tracked — all of them are

Corrected 10/08/2026 after reading the full RecruitCRM API. Leads and internal interviews are
**note types**; pitched candidates use RecruitCRM's **pitch feature**; client visits are
**meetings**. 2026 to date: 422 leads, 255 internal interviews, 92 job order forms.

Notes are now mirrored (60,000+ rows, 2018 onward) so the note-based ones are countable by
consultant and period. Nothing needed adding to RecruitCRM — the data was always there.

The remaining caveat is recording, not capability: these count what was logged. Low numbers may
mean low activity or low logging, exactly like Devyce call tagging.

A `Job Lead` deal stage also exists with zero deals in it. If it starts being used, leads will
live in two places and will need reconciling.

---

## 88 candidates are off limit — 61 of them are flagged here

RecruitCRM marks 88 candidates do-not-approach, with reasons recorded. `match_candidates` used to
return them; it now excludes them and reports `off_limit_excluded` rather than silently shortening
a shortlist. A single "engineer" search was surfacing 14.

Of the 88, **61 exist in our candidate mirror and carry the flag; 27 have never been synced**. That
is not a hole in the filter — the shortlist reads the same mirror, so anything it can surface it can
also exclude — but the two numbers are different and both are true.

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

---

**See also:** [Metrics and Definitions](Metrics-and-Definitions) for the intended definition · [Operations Runbook](Operations-Runbook) for fixing a feed · [Architecture](Architecture) for how data arrives · [Commands](Commands)
