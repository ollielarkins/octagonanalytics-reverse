-- 0063_near_live_deletion_detection.sql
-- Deletions were the one thing not near-live. Adds and edits land in ~2 minutes via the incremental
-- sync and webhooks, but a deleted record sat in reports until the nightly reconcile - up to 16
-- hours of a person who no longer exists appearing in searches and counts.
--
-- RecruitCRM does not tell us about deletions. All 8,806 webhooks received to date are full record
-- bodies carrying id and slug; a delete has no record to send, so there is no event to react to.
-- Detection has to be ours.
--
-- Per-record existence checks would be ~51,800 lookups a cycle, impossible inside the rate limit.
-- The paged list is far cheaper: 518 pages of 100 records. A full candidates pass every 30 minutes
-- averages ~0.29 req/s, against the ~1.25 req/s the history walk already sustains safely, and a
-- pass takes ~12 minutes across four drain chunks so passes never overlap on a 30-minute cycle.
-- clients (47 pages), jobs (61) and deals (16) are cheaper still and move to hourly, staggered so
-- they never contend with each other or with the candidates pass starting on the half hour.
--
-- Worst case for a deletion: 30 minutes for candidates, 1 hour for clients, jobs and deals.
--
-- Health thresholds follow. At the old 26h/50h an hourly reconcile could stop for most of a day
-- without warning, so they drop to 2h warn / 4h critical.

do $do$
begin
  if exists (select 1 from cron.job where jobname='backfill-candidates-pass') then
    perform cron.unschedule('backfill-candidates-pass');
  end if;
  perform cron.schedule('backfill-candidates-pass','*/30 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=backfill_all&entity=candidates&start_page=1&max_pages=150',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);

  if exists (select 1 from cron.job where jobname='recruitcrm-reconcile-clients') then
    perform cron.unschedule('recruitcrm-reconcile-clients');
  end if;
  perform cron.schedule('recruitcrm-reconcile-clients','5 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=clients',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);

  if exists (select 1 from cron.job where jobname='recruitcrm-reconcile-jobs') then
    perform cron.unschedule('recruitcrm-reconcile-jobs');
  end if;
  perform cron.schedule('recruitcrm-reconcile-jobs','12 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=jobs',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);

  if exists (select 1 from cron.job where jobname='recruitcrm-reconcile-deals') then
    perform cron.unschedule('recruitcrm-reconcile-deals');
  end if;
  perform cron.schedule('recruitcrm-reconcile-deals','18 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=deals',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb, timeout_milliseconds:=20000);$job$);
end
$do$;

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

revoke all on function public.sync_health() from public, anon, authenticated;
grant execute on function public.sync_health() to service_role;
