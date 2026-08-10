-- 0047_history_feed_and_health.sql
-- candidate_stage_events — the single source for the entire funnel — was frozen from 04/08/2026
-- 17:03 until 10/08/2026. Six days. Nobody noticed, and the dashboard reported "sync healthy"
-- throughout.
--
-- Cause: syncHistory() latches `last_status = 'complete'` when its one-off walk finishes and then
-- short-circuits on entry. The `history-resync` cron fired every minute for six days and returned
-- "already complete" every time. Hiring-stage webhooks route to entity=candidates, which refreshes
-- the candidate ROW; nothing wrote the event stream. The only other writer is the post-write
-- refresh in octagon-mcp, and no write has ever been made.
--
-- Why it was invisible: 0015 deliberately excluded `history` from sync_health, on the reasoning
-- that it was a one-off backfill that would false-alarm forever. That reasoning was right about the
-- backfill and wrong about the funnel, which had no other feed.
--
-- Fix, in three parts:
--   1. A new `history_recent` mode walks only candidates changed in the last N days — ~90 a day
--      against 16,600 total, so it is cheap where a full re-walk is 16,600 API calls.
--   2. This migration repoints the cron at it. The old every-minute full-walk job is removed.
--   3. history_recent joins sync_health, so the same stall becomes a red banner within 30 minutes.
--
-- Pacing: RecruitCRM rate-limits at roughly 4.6 req/s — a 50ms delay earned a 429 after 120
-- candidates. 700ms is comfortable. 50 candidates per run is ~35s.

select cron.unschedule('history-resync');

do $$
declare
  auth text := 'Bearer ' || current_setting('app.settings.anon_key', true);
begin
  -- Fall back to the literal used by 0005/0007/0012 when the setting isn't present.
  if auth is null or auth = 'Bearer ' then
    auth := 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk';
  end if;
  perform cron.schedule('history-recent', '*/10 * * * *', format(
    $q$select net.http_post(url:=%L, headers:=jsonb_build_object('Authorization',%L,'Content-Type','application/json'), body:='{}'::jsonb, timeout_milliseconds:=55000);$q$,
    'https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=history_recent&days=1&max_candidates=50&sleep_ms=700',
    auth));
end $$;

-- history_recent joins the health check. Every 10 minutes, so warn at 30 and critical at 120.
create or replace function public.sync_health()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg(entity, category, warn_min, crit_min) as (
    values
      ('candidates','live',10,30),
      ('clients','live',10,30),
      ('consultants','live',10,30),
      ('jobs','live',10,30),
      ('calls','live',10,30),
      ('deals','live',10,30),
      ('history_recent','live',30,120),
      ('reconcile:clients','reconcile',1560,3000),  -- 26h warn / 50h critical
      ('reconcile:jobs','reconcile',1560,3000),
      ('reconcile:deals','reconcile',1560,3000)
  ),
  -- history_recent writes free-form success text ("days=1 cands=50 +12ev"), so an allow-list of
  -- exact statuses would flag every healthy run. Match failure prefixes instead: error: and
  -- stopped: (the latter is how a rate-limit abort is recorded).
  ev as (
    select c.entity, c.category, c.warn_min, c.crit_min,
           s.last_run_at, s.last_status,
           round(extract(epoch from (now()-s.last_run_at))/60)::int as mins
    from cfg c left join sync_state s on s.entity = c.entity
  ),
  cls as (
    select entity, category, last_run_at, last_status, mins,
      case
        when last_run_at is null then 'critical'
        when category='live' and last_status is not null
             and (last_status like 'error:%' or last_status like 'stopped:%') then 'critical'
        when mins >= crit_min then 'critical'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when last_run_at is null then 'no sync run on record'
        when category='live' and last_status is not null
             and (last_status like 'error:%' or last_status like 'stopped:%') then 'error status: '||last_status
        when mins >= crit_min then 'stale: '||mins||' min since last run'
        when mins >= warn_min then 'slowing: '||mins||' min since last run'
        else 'fresh'
      end as reason
    from ev
  )
  select jsonb_build_object(
    'generated_at', now(),
    'overall', (select case
                  when bool_or(status='critical') then 'critical'
                  when bool_or(status='warn') then 'warn'
                  else 'ok' end from cls),
    'entities', (select jsonb_agg(jsonb_build_object(
        'entity', entity, 'category', category, 'last_run_at', last_run_at,
        'minutes_stale', mins, 'last_status', last_status,
        'status', status, 'reason', reason)
        order by (status='critical') desc, (status='warn') desc, entity) from cls)
  );
$function$;

revoke all on function public.sync_health() from public, anon, authenticated;
grant execute on function public.sync_health() to service_role;
