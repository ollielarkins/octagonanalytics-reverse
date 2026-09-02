-- 0062_candidates_reconcile_via_backfill_pass.sql
-- Swap the candidates reconcile over to the last_seen_at pass in 0061, and make health follow.
--
-- 02:00 starts a fresh pass: an explicit start_page=1 resets the cursor and stamps a new pass start.
-- Every 3 minutes continues an in-flight pass and no-ops once the pass reports complete. A full pass
-- is ~518 pages at 150 per invocation, so about four chunks.
--
-- reconcile:candidates is dropped from sync_health and backfill:candidates takes its slot - without
-- that swap the retired entity would go stale and trip critical for a job that no longer exists.

do $do$
begin
  if exists (select 1 from cron.job where jobname='recruitcrm-reconcile-candidates') then
    perform cron.unschedule('recruitcrm-reconcile-candidates');
  end if;
  if exists (select 1 from cron.job where jobname='backfill-candidates-pass') then
    perform cron.unschedule('backfill-candidates-pass');
  end if;
  if exists (select 1 from cron.job where jobname='backfill-candidates-drain') then
    perform cron.unschedule('backfill-candidates-drain');
  end if;

  perform cron.schedule('backfill-candidates-pass','0 2 * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill_all&entity=candidates&start_page=1&max_pages=150',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);

  perform cron.schedule('backfill-candidates-drain','*/3 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill_all&entity=candidates&max_pages=150',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);
end
$do$;

delete from public.sync_state where entity = 'reconcile:candidates';

create or replace function public.sync_health()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg(entity, category, warn_min, crit_min, strict_status) as (
    values
      ('candidates','live',10,30,true),
      ('clients','live',10,30,true),
      ('consultants','live',10,30,true),
      ('jobs','live',10,30,true),
      ('calls','live',10,30,true),
      ('deals','live',10,30,true),
      ('history_recent','live',25,60,false),
      ('notes','live',25,60,false),
      ('offlimit','reconcile',1560,3000,false),
      ('reconcile:clients','reconcile',1560,3000,false),
      ('reconcile:jobs','reconcile',1560,3000,false),
      ('reconcile:deals','reconcile',1560,3000,false),
      ('backfill:candidates','reconcile',1560,3000,false)
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

revoke all on function public.sync_health() from public, anon, authenticated;
grant execute on function public.sync_health() to service_role;
