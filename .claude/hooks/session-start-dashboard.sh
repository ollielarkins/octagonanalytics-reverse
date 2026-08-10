#!/usr/bin/env bash
# SessionStart hook: open every new chat with the live recruitment dashboard. get_dashboard is an
# interactive connector (MCP Apps) — its result renders automatically as an inline dashboard widget,
# so Claude just needs to call it.
#
# Two outputs:
#   additionalContext  - the rules for HOW to render it (injected silently, on every session event)
#   initialUserMessage - a simulated first user message that makes Claude run immediately, so the
#                        dashboard appears WITHOUT the user typing anything. Only emitted on a fresh
#                        `startup` (not resume/clear/compact) so it never fires mid-session; it is
#                        ignored by design in --print mode.
#
# Keep the context text free of double quotes and backslashes - it is embedded raw in the JSON below.

CONTEXT="At the very start of this chat, before responding to anything else, call the get_dashboard tool from the octagon-analytics connector. It is an interactive connector (MCP Apps): the result renders automatically as the inline Octagon dashboard widget (sync health, firm KPIs, 2026 funnel, deal pipeline, and the viewer's own KPIs/targets). Do NOT build your own artifact or markdown table for it - the widget is the dashboard. Alongside the widget, give a one-line text summary of the headline figures (the tool returns them as text) so they show even if the widget is slow; do NOT claim it 'loaded above' if you can't confirm it rendered. If the octagon-analytics connector isn't available, only then fall back to WebFetching https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/dashboard-data and presenting a compact summary. After the dashboard, give a brief 'your day' standup: call my_day and list the viewer's most urgent items (aging offers, stalled candidates, cold open roles) plus any weekly KPI they're behind on. If my_day cannot resolve the viewer to a consultant, say so in one line and skip the standup rather than guessing. Then continue with whatever the user asks."

INPUT=$(cat)
SOURCE=$(printf '%s' "$INPUT" | tr -d ' \n' | grep -o '"source":"[a-z]*"' | head -1 | cut -d'"' -f4)

if [ "$SOURCE" = "startup" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s","initialUserMessage":"Dashboard and my day."}}\n' "$CONTEXT"
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$CONTEXT"
fi
