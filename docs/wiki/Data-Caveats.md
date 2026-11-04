# Data Caveats

For anyone quoting a number outside the building: where the figures are soft, why, and what would
fix it.

*Last reviewed 04/11/2026.*

**On this page:** [Call categorisation](#call-categorisation) ·
[Funnel parity](#funnel-parity-with-recruitcrms-report) · [Only what is logged](#only-what-is-logged) ·
[Leave](#leave-is-not-in-recruitcrm) · [Deals and fees](#deals-and-fees) · [No invoices](#no-invoices) ·
[Placements](#placements-carry-no-money) · [Contacts](#contacts-are-mirrored-without-contact-details) ·
[Candidates](#candidates) · [Leavers and deleted records](#leavers-and-deleted-records) ·
[Fixed](#fixed-but-worth-knowing)

Figures here are measured with dated queries, not estimated.

## Call categorisation

> [!CAUTION]
> **The biggest soft spot in the platform.** BD and client call KPIs count only *tagged* Devyce
> calls, and most calls are not tagged.

All calls, by month (`call_activity`, to 03/11/2026):

| Month | Calls | Tagged | Rate |
|---|---|---|---|
| May 2026 | 727 | 189 | 26.0% |
| June | 2,029 | 530 | 26.1% |
| July | 2,066 | 484 | 23.4% |
| August | 3,626 | 478 | 13.2% |
| September | 3,996 | 370 | **9.3%** |
| October | 4,180 | 501 | 12.0% |

The calls that matter for the targets are those of 30 seconds or more to client contacts. Those
are tagged more often: 18.6% in August, 25.3% in September, 26.0% in October. Even so, a recruiter
making ten real BD calls records two or three.

Per person, the busiest desks tagged least (measured 01/10 to 25/10/2026). Never coach off a BD or
client call number without that person's tagging rate beside it.

What exists to help:

| Measure | Where |
|---|---|
| `/tagcalls`: each untagged call with a suggested category to accept or change | Chat |
| One-press tagging of today's untagged client-contact calls | Coach DM, 16:45 |
| Today's untagged count per person | Day End brief, 17:30 |
| Last week's tagging rate per person, against the week before | Week Ahead brief, Monday |
| `likely_untagged`: the untagged calls that were probably BD or client calls | `kpis_report`, `call_activity_report` (0148) |

`likely_untagged` uses `likely_call_type()` (rules in
[Metrics and Definitions](Metrics-and-Definitions#calls)). It agreed with recruiters' own tags on
84% of 1,654 tagged calls, so roughly one in six guesses is wrong. It is shown **beside** the tagged
count and **never added in**: the targets still count tagged calls only. Nothing is tagged
automatically, because numbers are shared and some people are both candidates and clients; a call is
tagged only when the recruiter presses or confirms.

## Funnel parity with RecruitCRM's report

The funnel reads RecruitCRM's API (`/candidates/{slug}/history`), not its candidate lifecycle report.
Measured 08/09/2026 across five months, actor-attributed, distinct pairs at latest occurrence:

- 34 of 50 stage-months exact; total variance 30 rows in 7,935 (**~0.4%**).
- Offered, Placed, 2nd and 3rd Interview exact in every month tested.
- The residual is confined to Shortlist, CV Sent and Rejected - Consultant.

The gap is between RecruitCRM's API and its own report layer: the report omits rows the API returns,
for live, unmerged, undeleted candidates. Every exclusion rule that closed it broke a stage that was
exact, so the API is the system of truth and the last 0.4% is not chased (decided 08/09/2026).

Shortlist is also partly adopted: 1,948 shortlisted pairs against 3,009 CVs sent in 2026 to
04/11/2026. Some desks skip straight to CV Sent, so a shortlist→CV rate means nothing.

RecruitCRM's hiring-stage history thins out badly before 2026, which is why reports default to
2026 onward. Comparisons across that boundary are not like-for-like.

## Only what is logged

Leads, internal interviews and job order forms are note types; pitches use RecruitCRM's pitch
feature; client visits are meetings. All count **what was logged**. 2026 to 04/11/2026: 583 leads,
335 internal interviews, 121 job order forms.

Meetings count only when typed. This quarter to 04/11/2026: 286 meetings, 216 untyped, 3 typed
Client Meeting. An untyped meeting cannot count as a visit until it is typed (`meeting_review`).

## Leave is not in RecruitCRM

RecruitCRM's diary holds no leave: none of the 286 meetings this quarter looks like leave. Nothing
on the platform knows who is off. The coach asks instead ("Away? Pick your last day off") and skips
a day with nothing logged at all. KPI and queue figures for someone on leave will look like a bad
week.

## Deals and fees

| Issue | Effect | Fix |
|---|---|---|
| **Salary entered in thousands**: 13 of 2026's Won deals carry e.g. "39" for £39,000 (0143) | Average salary in `/fees` is wrong; fee % cannot be suggested from value ÷ salary | `/hygiene` lists them; correct with `/won` |
| **Missing fee %, salary, value or start date** on Won deals | Fee analysis averages over fewer deals; aftercare cannot see deals with no start date | `/hygiene`, then `/won` |
| **Two deals with a fee % above 100** (one reads 7000) | Mean fee % 26.2% on Won deals against a median of 18.0% | Quote the median. `fee_analysis` drops values above 100 and says how many |
| **64 ghost deals** with no RecruitCRM id, all from a one-off import on 08/07/2026 (51 CV Sent, 9 Interview Request, 4 Placed, all with no value) | Unreachable by every sync path; inflate deal counts on the pipeline table. Billing unaffected: none are Won | Pending deletion |
| **Placements with no Won deal** | Not billed: billing is Won deal value only | `/hygiene`; the coach flags one after 14 days |

## No invoices

RecruitCRM's invoices are not mirrored, so the platform cannot say whether a Won deal has been
invoiced or paid. Billing means Won deal value, not cash. Check invoice status in RecruitCRM.

## Placements carry no money

RecruitCRM's placement record is a join (candidate, job, company, deal) with no fee or salary, so
the `placements` table is empty and stays empty. A placement is a Placed stage event; its fee is a
Won deal on the same job, paired one to one by `placements_with_fees`. The Placed stage records the
start date only in a stage remark, which is not mirrored, so aftercare works from Won deals' start
dates.

## Contacts are mirrored without contact details

Since 0145 (03/11/2026) contacts are mirrored: 18,399 records with name, company, job title, owner
and dates, synced every 15 minutes and reconciled daily. **Email and phone are not mirrored**;
`client_status` and `send_email` read them live from RecruitCRM. Calls are mostly logged against the
contact rather than the company, so company-level views (lapsed clients' last touch, BD per client)
only became complete with this mirror.

## Candidates

| Figure | As at 04/11/2026 | Means |
|---|---|---|
| Candidates on the CRM | 53,235 | Every live candidate record |
| Candidates in the pipeline | 20,507 | Have moved through at least one hiring stage |
| With skills on file | 45,168 (84.8%) | `match_candidates` only considers these, so a missing candidate may simply have no skills |
| Off limit in the mirror | 93 | Excluded from matching and reported as `off_limit_excluded` |

The off-limit mirror refreshes hourly, but every client-facing write also checks RecruitCRM live (pitch, CV Sent and other stage moves, assigning, showing to the
client, email) and fails closed: if the check cannot run, the write is refused.

## Leavers and deleted records

**Leavers stay in totals, tagged "left".** Their activity is credited to whoever did the work and
never reattributed. In billing a leaver appears when they own Won revenue this quarter or open
pipeline. Their live jobs disappear from every desk until moved with `/handover`; `/hygiene` lists
them.

**Deleted records are hidden from operations, not from history** (ratified 15/09/2026). A deleted
candidate, job, client or deal leaves search, matching, the live pipeline and chase lists, but stays
in the funnel, activity and rankings, so deleting a candidate does not change last quarter's CV
sends. Billing and pipeline exclude deleted deals (0133). Deletions arrive instantly by webhook,
with reconcile page-walks as the backstop: hourly for clients, jobs and deals, daily for
consultants and contacts.

## Fixed, but worth knowing

| Was | Fixed | Still matters because |
|---|---|---|
| ~40% of jobs had no client (a sync lookup capped at 1,000 rows) | 10/08/2026; now 9 of 6,083, none open | Client or account analysis from before 10/08/2026 ran on ~60% of the data and should be re-run |
| Billing had no quarter end and counted deleted deals; pipeline took in Declined and Placed | 29/10/2026 (0133) | Billing and pipeline figures quoted before then were overstated |
| Leads, internal interviews, job order forms and visits documented as "not tracked" | 10/08/2026 | They were always in RecruitCRM; earlier reports said otherwise |

---

**Related:** [Metrics and Definitions](Metrics-and-Definitions) · [Operations Runbook](Operations-Runbook) · [Architecture](Architecture) · [Inbox](Inbox)
