#!/usr/bin/env bash
# SessionStart hook: open every new chat with the live recruitment dashboard. get_dashboard is an
# interactive connector (MCP Apps) — its result renders automatically as an inline dashboard widget,
# so Claude just needs to call it. Emits additionalContext (an instruction to Claude) on stdout.
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"At the very start of this chat, before responding to anything else, call the get_dashboard tool from the octagon-analytics connector. It is an interactive connector (MCP Apps): the result renders automatically as the inline Octagon dashboard widget (sync health, firm KPIs, 2026 funnel, deal pipeline, and the viewer's own KPIs/targets). Do NOT build your own artifact or markdown table for it - the widget is the dashboard. Alongside the widget, give a one-line text summary of the headline figures (the tool returns them as text) so they show even if the widget is slow; do NOT claim it 'loaded above' if you can't confirm it rendered. If the octagon-analytics connector isn't available, only then fall back to WebFetching https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/dashboard-data and presenting a compact summary. Then continue with whatever the user asks."}}
JSON
