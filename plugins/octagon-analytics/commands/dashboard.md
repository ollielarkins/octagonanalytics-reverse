---
description: Full live recruitment dashboard — KPIs, 2026 funnel, per-consultant performance, deal pipeline (with sync-health check).
---

Call the `get_dashboard` tool from the **octagon-analytics** connector.

FIRST inspect the payload's `health` object: if `health.overall` is not `"ok"`, lead with a clear
banner naming the stale or failing feeds (each `health.entities[].entity` with its `.reason`) and
warn that the figures below may be stale. If it is `"ok"`, a one-line "sync healthy" note is enough.

Then present the full dashboard as compact markdown tables — no heavy styling:
- the KPI cards,
- the 2026 funnel,
- per-consultant performance (attributed by job owner),
- the deal pipeline.

If the tool returns an authentication error, tell the user their `OCTAGON_MCP_TOKEN` is missing or
invalid and point them at `ONBOARDING.md`.
