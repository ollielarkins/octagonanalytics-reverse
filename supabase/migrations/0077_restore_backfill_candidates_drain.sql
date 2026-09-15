-- 0077_restore_backfill_candidates_drain.sql
-- 0074 restored backfill-candidates-pass but not backfill-candidates-drain. They are a pair and
-- neither works alone: pass (start_page=1) RESETS the cursor and begins a pass; drain (no start_page)
-- RESUMES from sync_state.cursor and no-ops once last_status says complete. A full pass is ~518 pages
-- at 150 per invocation - about four drain chunks, ~12 minutes.
--
-- With pass alone, every 30 minutes a fresh pass walks pages 1-150 of 518 and nothing continues it.
-- resume_next_page is written to the cursor and then thrown away by the next pass's start_page=1. The
-- pass never reports complete, so retire_unseen_candidates - the entire candidate deletion-detection
-- path - never runs at all, while backfill:candidates sits critical and looks merely stale.
--
-- Defined in 0062; missed when 0074 rebuilt the schedule from 0063 and the runbook.
do $do$
begin
  if exists (select 1 from cron.job where jobname='backfill-candidates-drain') then
    perform cron.unschedule('backfill-candidates-drain');
  end if;
  perform cron.schedule('backfill-candidates-drain','*/3 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill_all&entity=candidates&max_pages=150',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);
end
$do$;
