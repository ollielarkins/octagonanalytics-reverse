---
description: Headline recruitment KPIs only — placements, open jobs, pipeline value and firm totals, concise.
---

Call the `get_dashboard` tool from the **octagon-analytics** connector.

Glance at `health.overall` first — if it is not `"ok"`, add a single-line warning naming the
affected feeds (`health.entities[].entity`) before the numbers.

Then present ONLY the headline KPIs, concisely:
- placements (2026 and all-time),
- open jobs,
- open pipeline value,
- Won revenue,
- firm totals (candidates, clients, jobs, active consultants).

Do NOT include the funnel, the per-consultant breakdown, or the deal-pipeline table — just the
top-line numbers.

If the tool returns an authentication error, tell the user their `OCTAGON_MCP_TOKEN` is missing or
invalid and point them at `ONBOARDING.md`.
