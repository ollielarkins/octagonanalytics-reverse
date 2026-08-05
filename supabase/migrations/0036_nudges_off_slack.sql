-- 0036_nudges_off_slack.sql
-- Move proactive coaching nudges off Slack and into Claude. The daily-standup and admin-digest crons
-- posted to a Slack webhook (Slack is deprioritised). They're unscheduled here; the equivalent is now
-- delivered in Claude at the start of a chat — the dashboard widget shows the viewer's KPIs/targets,
-- and the org instructions have Claude surface a brief "your day" (my_day: aging offers, stalled
-- candidates, cold roles) alongside it. See rollout/claude-system-instructions.md §3/§6.

do $$ begin perform cron.unschedule('daily-standup'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('admin-digest');  exception when others then null; end $$;
