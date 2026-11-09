-- 0158_remove_team_briefs.sql
-- 09/11/2026: the "(Claude) - Team Briefs" Slack app has been deleted. Its scheduled sends stopped
-- on 05/11/2026 (0150) when the Octagon Coach took over. This removes what only that app used:
--   post_digest()            posted the morning/evening/weekly digest to #briefs by its webhook
--                            (the /digest command and the connector's post_digest tool, removed in
--                            octagon-mcp 3.101.0)
--   post_digest_if_due()     the old scheduler for those posts
--   action_queue_if_due()    called the daily-queue function for the 08:30 queue DMs and the Monday
--                            manager exceptions DM (daily-queue and slack-actions are deleted)
--   coach_go_live_0150(), coach_add_wave2_0150()  spent one-off switches from 0150
--   app_settings             digest_webhook_url, action_queue_pilot, action_queue_shadow,
--                            action_queue_shadow_email, manager_exceptions_emails
--   sync_state 'action_queue'
--
-- Kept on purpose:
--   slack_queue_messages                which Slack message each queue DM was (2 rows); kept by choice
--   action_queue(), team_exceptions()   /queue and /exceptions in Claude
--   action_queue_done                   past Done presses; action_queue() and coach_nudges() read it
--   digest_morning/evening/weekly()     the digest-email function renders from them
--   feature_area()                      still labels old 'post_digest' rows in the usage log

drop function if exists public.post_digest(text);
drop function if exists public.post_digest_if_due(text, integer);
drop function if exists public.action_queue_if_due(integer);
drop function if exists public.coach_go_live_0150();
drop function if exists public.coach_add_wave2_0150();

delete from public.app_settings
 where key in ('digest_webhook_url', 'action_queue_pilot', 'action_queue_shadow',
               'action_queue_shadow_email', 'manager_exceptions_emails');
delete from public.sync_state where entity = 'action_queue';
