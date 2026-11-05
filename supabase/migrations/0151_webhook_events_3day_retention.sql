-- 0151_webhook_events_3day_retention.sql
-- 05/11/2026: database at 449 of the Free plan's 500 MB. Nothing reads webhook_events beyond a few
-- days (they are raw RecruitCRM payloads for debugging), so retention drops from 7 days to 3.
-- Same job name and schedule, so cron_manifest is unchanged.
-- Applied live the same day, alongside a one-off `vacuum full net._http_response;` (155 MB of dead
-- space from pg_net's own clean-up, 633 live rows) that took the database from 414 MB to 259 MB.

select cron.schedule('purge-webhook-events', '45 3 * * *',
  $$delete from public.webhook_events where received_at < now() - interval '3 days'$$);
