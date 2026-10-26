# Octagon Analytics

Live recruitment analytics on top of RecruitCRM, with a Claude interface recruiters use directly to
ask questions and take defined actions.

RecruitCRM stays the system of record. This platform mirrors it into Supabase, defines every metric
exactly once, and serves those definitions to both the dashboards and Claude — so the two can never
disagree.

> [!WARNING]
> **`dashboard-data` is unauthenticated and this repo is public.** Firm revenue and every
> consultant's individual figures are readable by anyone with the URL. See
> [Architecture](Architecture#dashboard-data-is-unauthenticated). Still open as of 26/10/2026.

---

## I want to…

| | Go to |
|---|---|
| Get set up and connected | [Onboarding](Onboarding) → Part 1 |
| See every slash command | [Commands](Commands) |
| Know what I can ask it | [Tools Reference](Tools-Reference) |
| Understand what a number counts | [Metrics and Definitions](Metrics-and-Definitions) |
| Check whether a number can be trusted | [Data Caveats](Data-Caveats) |
| Work out why something looks wrong | [Data Caveats](Data-Caveats), then [Runbook → Incidents](Operations-Runbook#incidents--10082026) |
| Deploy, backfill, or mint a token | [Operations Runbook](Operations-Runbook) |
| Understand how the data flows | [Architecture](Architecture) |

## The pages

| Page | For |
|---|---|
| **[Onboarding](Onboarding)** | Getting set up and productive. Start here if you're a recruiter. |
| **[Commands](Commands)** | All 75 slash commands, grouped by what you are trying to do. |
| **[Tools Reference](Tools-Reference)** | Every question the system can answer, and how to ask it. |
| **[Metrics and Definitions](Metrics-and-Definitions)** | What each number actually means. Read before quoting anything. |
| **[Data Caveats](Data-Caveats)** | Where the numbers are soft, and why. Read this second. |
| **[Architecture](Architecture)** | How data gets from RecruitCRM to your screen. |
| **[Operations Runbook](Operations-Runbook)** | Deploys, backfills, tokens, incidents. Admins only. |

---

## Current state — 26/10/2026

Live and in use. 2,345 tool calls from 7 people in the last 30 days, and 412 audited writes since
12/08/2026, 361 of them in the last 30 days. Every write stays two-step: preview, then an explicit
confirm.

### The platform

| | |
|---|---|
| Connector | octagon-mcp 3.81.1 — 72 tools, 26 prompts |
| Commands | 75 slash commands in four plugins |
| Sync | health-monitored feeds plus a cron manifest watchdog (22 jobs declared) |
| Webhooks | 15 subscriptions, including the four `*.deleted` events |
| Slack | Morning, Day End and Week Ahead briefs in #claude-teambriefs; the 08:30 action queue DM (pilot of four); the Monday manager exceptions DM |
| Active tokens | 20, held by 11 people (OAuth sessions are rows of their own) |

### The data

| | |
|---|---|
| Candidates | 53,007 |
| Jobs | 6,073 (137 open) |
| Clients | 4,817 |
| Deals | 1,673 |
| Notes | 101,448, 2018 onward |
| Devyce calls | 16,030, from 13/03/2026 — see the warning below |
| Meetings | 220, this quarter and last |

> [!CAUTION]
> **The BD/client call KPIs depend on call tagging.** 26% in May, 9% in September, 12% in October.
> Those targets count only *categorised* Devyce calls, so they understate reality. `/tagcalls` is the
> fix. See [Data Caveats](Data-Caveats#call-categorisation).

### What changed in October 2026

Bhav's priorities 1 to 8, all live by 26/10/2026:

1. **Diary in the briefs and skills.** Interviews tomorrow and feedback due, per consultant, from
   RecruitCRM's own diary (`schedule`, `diary_digest`).
2. **Call tagging.** `/tagcalls`, an untagged-calls line in Day End, and a weekly tagging rate.
3. **One Won deal per placement.** Extra Won deals show as separate, unmatched fees.
4. **The daily action queue.** An 08:30 Slack DM of ranked calls with Done buttons; drafting in
   your own Claude via "prep my queue".
5. **Weekly plan from billing.** Worked back from the quarter's target, never below the minimums.
6. **Client visits.** At least 2 per quarter, counted, with who to visit and why (`/visitplan`).
7. **Event-triggered drafts.** New jobs, client rejections and Friday Push & Tell go into the queue.
8. **Manager exceptions.** Only people with something to act on (`/exceptions`, Monday DM).

Also: `/intake` from Devyce call summaries, Internal Job Descriptions read from the file, job order
forms writable from Claude, and a rule that RecruitCRM is never changed through a browser. See
[`docs/DECISIONS.md`](https://github.com/ollielarkins/octagonanalytics-reverse/blob/main/docs/DECISIONS.md).

---

## Ground rules

1. **RecruitCRM is the system of record.** Writes go there; the mirror catches up via the normal
   sync. Never edit the mirror to "fix" a number.
2. **One definition per metric.** If a figure appears in two places it comes from the same view or
   RPC. Never write ad-hoc logic against the raw tables.
3. **Candidate names are PII.** Internal only. Not client-facing unless already shared with that
   client. No bulk export.
4. **Never invent a number.** If the data can't answer, say so.
