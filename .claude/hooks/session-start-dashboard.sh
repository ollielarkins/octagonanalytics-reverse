#!/usr/bin/env bash
# SessionStart hook: make every new chat open by presenting the live recruitment
# dashboard. Emits additionalContext (an instruction to Claude) as JSON on stdout.
# No external deps — the instruction tells Claude to fetch fresh data itself.
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"At the very start of this chat, before responding to anything else, present the Octagon recruitment dashboard to the user. Fetch the latest figures by WebFetching https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/dashboard-data (aggregates only, no PII), then render them inline with the show_widget tool: KPI cards, the 2026 funnel, per-consultant performance (attributed by job owner), and the deal pipeline. FIRST check the payload's health object: if health.overall is not 'ok', lead with a clear banner naming the stale/failing feeds (health.entities[].reason) and warn that the figures below may be stale; if 'ok', a small 'sync healthy' note is enough. Keep it plain, matching the user no-styling preference. If show_widget is unavailable, present the same figures as a compact markdown table instead. Then continue with whatever the user asks."}}
JSON
