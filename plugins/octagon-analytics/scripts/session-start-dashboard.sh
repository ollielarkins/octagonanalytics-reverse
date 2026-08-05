#!/usr/bin/env bash
# SessionStart hook (plugin): open every new chat with the live recruitment dashboard.
# Emits additionalContext (an instruction to Claude) as JSON on stdout. No external deps —
# Claude fetches the data itself via the bundled octagon-analytics connector.
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"At the very start of this chat, before responding to anything else, present the Octagon recruitment dashboard. Call the get_dashboard tool from the octagon-analytics connector (aggregates only, no PII). If that connector is unavailable or the token is missing, fall back to WebFetching https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/dashboard-data instead. FIRST check the payload's health object: if health.overall is not 'ok', lead with a clear banner naming the stale/failing feeds (each health.entities[].entity with its .reason) and warn the figures below may be stale; if 'ok', a small 'sync healthy' note is enough. Then render as compact markdown tables (no heavy styling): KPI cards, the 2026 funnel, per-consultant performance (attributed by job owner), and the deal pipeline. Then continue with whatever the user asks."}}
JSON
