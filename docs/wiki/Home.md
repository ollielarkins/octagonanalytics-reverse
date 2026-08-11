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

Live and in use for reads. The write path exists and is broad — jobs, deals, candidates, companies,
contacts, pitches, meetings, tasks, hotlists, email and deletions — but **no write has ever been
executed**: `audit_log` is empty. Every preview works; no confirm has been run.

| | |
|---|---|
| Connector version | octagon-mcp 3.40.1 |
| Sync | 12 feeds, health-monitored |
| Candidates mirrored | 16,600+ (6,100+ with pipeline activity) |
| Jobs | ~5,980 (130+ open, 99.8% linked to a client) |
| Clients | ~4,600 |
| Deals | 1,600 |
| Notes | 60,000+ mirrored, 2018 onward |
| Devyce calls | ~5,000 since 13/03/2026 |
| Off limit | 88 in RecruitCRM, 61 flagged here — excluded from shortlists |
| Adoption | 2 people have ever used it |

That last row is still the honest headline. The platform is built, broad, and barely used.

## Ground rules

1. **RecruitCRM is the system of record.** Writes go there; the mirror catches up via the normal
   sync. Never edit the mirror to "fix" a number.
2. **One definition per metric.** If a figure appears in two places it comes from the same view or
   RPC. Never write ad-hoc logic against the raw tables.
3. **Candidate names are PII.** Internal only. Not client-facing unless already shared with that
   client. No bulk export.
4. **Never invent a number.** If the data can't answer, say so.
