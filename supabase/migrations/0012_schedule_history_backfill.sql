-- 0012_schedule_history_backfill.sql
-- TEMPORARY driver: run the history backfill every minute until it self-marks
-- 'complete' (then ticks are cheap no-ops). UNSCHEDULE once complete:
--   select cron.unschedule('recruitcrm-history-backfill');
-- Each tick processes ~70 candidates' /history (synchronous, < ~45s), rate-safe.

select cron.schedule(
  'recruitcrm-history-backfill',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=history&max_candidates=70',
    headers := jsonb_build_object(
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk',
      'Content-Type', 'application/json'
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);
