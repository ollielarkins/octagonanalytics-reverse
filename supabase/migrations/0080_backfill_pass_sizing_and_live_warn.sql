-- 0080_backfill_pass_sizing_and_live_warn.sql
-- Two corrections, both of the same kind: a threshold that never matched the cadence it measured.
--
-- 1. max_pages=150 is more than one background invocation survives. Measured 15/09: a 20-page pass
--    persisted in 42s, so ~2.1s/page, putting 150 pages at ~315s - the task is killed before
--    backfillLoop returns, and nothing persists at all because the sync_state upsert comes after it.
--    That is why the 09:00 pass returned 202 and wrote nothing, and why backfill:candidates looked
--    "stale" rather than failing: a killed background task leaves no trace.
--
--    40 pages is ~84s. A 518-page pass is then 13 drain chunks at 3-minute spacing, about 39 minutes -
--    longer than the */30 gap before the next pass resets the cursor to page 1. So the pass moves to
--    hourly at :40, clear of the reconciles at :05/:12/:18 and the quarter-hour incrementals. A pass
--    starting at :40 finishes around :19 and idles until the next one.
--
--    Cost: worst-case candidate deletion latency goes from 30 minutes to 1 hour, matching clients,
--    jobs and deals. A pass that completes in an hour beats one that never completes at all.
--
-- 2. Live feeds warn at 10 minutes but recruitcrm-incremental-sync runs every 15, so clients, jobs,
--    calls and consultants warned for 5 minutes in every 15 - permanently, by construction. Nothing
--    was wrong when they did. That is worse than useless: a health panel that cries wolf on schedule
--    teaches people to stop reading it. warn moves to 20 minutes; critical stays at 30, so a single
--    missed cycle still escalates. candidates and deals rarely tripped it because webhooks keep them
--    fresh - the gap only ever showed on the four entities RecruitCRM sends no webhooks for.

create or replace function public.sync_health()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with cfg(entity, category, warn_min, crit_min, strict_status) as (
    values
      ('candidates','live',20,30,true),
      ('clients','live',20,30,true),
      ('consultants','live',20,30,true),
      ('jobs','live',20,30,true),
      ('calls','live',20,30,true),
      ('deals','live',20,30,true),
      ('history_recent','live',25,60,false),
      ('notes','live',25,60,false),
      ('offlimit','reconcile',1560,3000,false),
      ('reconcile:clients','reconcile',120,240,false),
      ('reconcile:jobs','reconcile',120,240,false),
      ('reconcile:deals','reconcile',120,240,false),
      ('backfill:candidates','reconcile',120,240,false)
  ),
  good(status) as (values ('ok'),('caught_up'),('complete'),('resume_next_page')),
  ev as (
    select c.entity, c.category, c.warn_min, c.crit_min, c.strict_status,
           s.last_run_at, s.last_status,
           round(extract(epoch from (now()-s.last_run_at))/60)::int as mins
    from cfg c left join sync_state s on s.entity = c.entity
  ),
  cls as (
    select entity, category, last_run_at, last_status, mins,
      case
        when last_run_at is null then 'critical'
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'critical'
        when mins >= crit_min then 'critical'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when last_run_at is null then 'no sync run on record'
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'error status: '||last_status
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

do $do$
begin
  if exists (select 1 from cron.job where jobname='backfill-candidates-pass') then
    perform cron.unschedule('backfill-candidates-pass');
  end if;
  perform cron.schedule('backfill-candidates-pass','40 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill_all&entity=candidates&start_page=1&max_pages=40',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);

  if exists (select 1 from cron.job where jobname='backfill-candidates-drain') then
    perform cron.unschedule('backfill-candidates-drain');
  end if;
  perform cron.schedule('backfill-candidates-drain','*/3 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill_all&entity=candidates&max_pages=40',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);
end
$do$;

-- The manifest is the declared truth, so it moves with the schedule. Without this the watchdog added
-- in 0078 would correctly report the new cadence as drift.
update public.cron_manifest set schedule = '40 * * * *' where jobname = 'backfill-candidates-pass';
