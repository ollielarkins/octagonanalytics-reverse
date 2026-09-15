-- 0074_restore_sync_crons.sql
-- Restores the sync schedule. On 10/09/2026 every live feed stopped between 12:05 and 14:20 and the
-- entities held their last good sync_state row, so the dashboard showed "stale" rather than "dead" —
-- the same failure shape 0005's comment warned about, one layer up. The cause was not a failing job:
-- the jobs were gone from cron.job entirely. Only reconcile-consultants, offlimit-refresh, the
-- digests and the purges survived, which is why those four kept reporting healthy.
--
-- Nothing here is new. Each job is restored to exactly what its own migration defines:
--   recruitcrm-incremental-sync   0005  every 15 min, entity=all
--   history-recent                0060  every minute, 50 candidates at 550ms spacing
--   notes-recent                  (20260810155048, applied but no file in this repo) every 15 min
--   backfill-candidates-pass      0063  every 30 min — it survived at 0012's '0 2 * * *' and with no
--                                       timeout_milliseconds, so pg_net cut it at its 5s default
--   recruitcrm-reconcile-clients  0063  hourly at :05
--   recruitcrm-reconcile-jobs     0063  hourly at :12
--   recruitcrm-reconcile-deals    0063  hourly at :18
--   sync-health-watchdog          0015  every 5 min
--
-- The reconciles stay staggered (:05/:12/:18) so they never contend with each other or with the
-- candidates pass starting on the half hour.
--
-- Every job is unscheduled first where present, so this is safe to re-run.

do $do$
declare
  anon_key text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk';
  base     text := 'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync';
  j        record;
begin
  for j in
    select * from (values
      ('recruitcrm-incremental-sync',  '*/15 * * * *', '?mode=incremental&entity=all',                        55000),
      ('history-recent',               '* * * * *',    '?mode=history_recent&max_candidates=50&sleep_ms=550', 55000),
      ('notes-recent',                 '*/15 * * * *', '?mode=notes_recent&max_pages=3',                      55000),
      ('backfill-candidates-pass',     '*/30 * * * *', '?mode=backfill_all&entity=candidates&start_page=1&max_pages=150', 20000),
      ('recruitcrm-reconcile-clients', '5 * * * *',    '?mode=reconcile&entity=clients',                      20000),
      ('recruitcrm-reconcile-jobs',    '12 * * * *',   '?mode=reconcile&entity=jobs',                         20000),
      ('recruitcrm-reconcile-deals',   '18 * * * *',   '?mode=reconcile&entity=deals',                        20000)
    ) as t(jobname, schedule, qs, timeout_ms)
  loop
    if exists (select 1 from cron.job where jobname = j.jobname) then
      perform cron.unschedule(j.jobname);
    end if;
    perform cron.schedule(j.jobname, j.schedule, format(
      $job$select net.http_post(
        url:=%L,
        headers:=jsonb_build_object('Authorization','Bearer %s','Content-Type','application/json'),
        body:='{}'::jsonb,
        timeout_milliseconds:=%s);$job$,
      base || j.qs, anon_key, j.timeout_ms));
  end loop;

  if exists (select 1 from cron.job where jobname = 'sync-health-watchdog') then
    perform cron.unschedule('sync-health-watchdog');
  end if;
  perform cron.schedule('sync-health-watchdog', '*/5 * * * *', $job$select public.check_sync_health();$job$);
end
$do$;
