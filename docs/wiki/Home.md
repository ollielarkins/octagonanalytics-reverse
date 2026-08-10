# Octagon Analytics

Live recruitment analytics on top of RecruitCRM, with a Claude interface recruiters use directly to
ask questions and take defined actions.

RecruitCRM stays the system of record. This platform mirrors it into Supabase, defines every metric
exactly once, and serves those definitions to both the dashboards and Claude — so the two can never
disagree.

## Start here

| Page | For |
|---|---|
| **[Onboarding](Onboarding)** | Getting set up and productive. Start here if you're a recruiter. |
| **[Tools Reference](Tools-Reference)** | Every question the system can answer, and how to ask it. |
| **[Metrics and Definitions](Metrics-and-Definitions)** | What each number actually means. Read before quoting anything. |
| **[Data Caveats](Data-Caveats)** | Where the numbers are soft, and why. Read this second. |
| **[Architecture](Architecture)** | How data gets from RecruitCRM to your screen. |
| **[Operations Runbook](Operations-Runbook)** | Deploys, backfills, tokens, incidents. Admins only. |

## Current state — 10/08/2026

Live and in use for reads. The write path exists but has never been exercised: `audit_log` is empty,
so no change has yet been made to RecruitCRM through Claude.

| | |
|---|---|
| Connector version | octagon-mcp 3.26.0 |
| Sync | 9 entities, every 2 minutes, health-monitored |
| Candidates mirrored | 16,629 (6,133 with pipeline activity) |
| Jobs | 5,975 (132 open) |
| Clients | 4,597 |
| Deals | 1,600 |
| Devyce calls | ~5,000 since 13/03/2026 |
| Adoption | 17 tool calls in the last 30 days, from 2 people |

That last row is the honest headline. The platform is built and largely unused. Everything in these
pages is written on the assumption that the next milestone is people using it, not more features.

## Ground rules

1. **RecruitCRM is the system of record.** Writes go there; the mirror catches up via the normal
   sync. Never edit the mirror to "fix" a number.
2. **One definition per metric.** If a figure appears in two places it comes from the same view or
   RPC. Never write ad-hoc logic against the raw tables.
3. **Candidate names are PII.** Internal only. Not client-facing unless already shared with that
   client. No bulk export.
4. **Never invent a number.** If the data can't answer, say so.
