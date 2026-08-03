-- 0005_schedule_incremental_sync.sql
-- Schedule the incremental RecruitCRM→Supabase sync every 15 minutes.
-- Invokes the (verify_jwt=true) edge function via pg_net, authorised with the
-- public anon key (a valid JWT that passes the gateway; the function itself uses
-- the service role internally). Data freshness target: ~15 min.

select cron.schedule(
  'recruitcrm-incremental-sync',
  '*/15 * * * *',
  $$
  select net.http_post(
    url     := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=incremental&entity=all',
    headers := jsonb_build_object(
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk',
      'Content-Type', 'application/json'
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);
