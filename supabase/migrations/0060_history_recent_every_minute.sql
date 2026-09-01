-- 0060_history_recent_every_minute.sql
-- Pacing, after measuring the queue rather than guessing at it.
--
-- 0059 set history-recent to every 3 minutes at 50 candidates. A pass takes ~40s, so the walk sat
-- idle 140s in every 180 - a 22% duty cycle against a backlog of ~17,000. That put the full drain
-- at 17 hours.
--
-- Worth being precise about what that backlog actually is. The one-off `history` backfill walked
-- every candidate by id and latched complete on 04/08/2026 at cursor 51362. Anything it covered
-- that has not changed since cannot be missing events. Splitting the queue on that basis:
--
--   1,813  at risk  - created after cursor 51362, or changed since 04/08/2026
--  15,532  covered  - already walked by the completed backfill, unchanged since
--
-- So only ~10% of the queue can actually be wrong, and because the queue is ordered by updated_date
-- descending, that 10% is at the front. The rest is redundant re-verification, which is worth
-- keeping (it confirms the backfill) but not worth waiting on.
--
-- Every minute: throughput triples to 3,000/hour. The at-risk set drains in ~35 minutes, the full
-- tail in under six hours. Sustained rate is 50 requests per 60s = 0.83 req/s against the ~4.6
-- req/s the code comments record as earning a 429, so roughly a 5x margin. If a pass ever overruns
-- the interval the overlap is harmless: upserts are keyed on cse_natural_key, so a candidate walked
-- twice writes identical rows.

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'history-recent') then
    perform cron.unschedule('history-recent');
  end if;
  perform cron.schedule(
    'history-recent',
    '* * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=history_recent&max_candidates=50&sleep_ms=550',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb,
      timeout_milliseconds:=55000);$job$);
end
$do$;
