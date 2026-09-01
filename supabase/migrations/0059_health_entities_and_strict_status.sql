-- 0059_health_entities_and_strict_status.sql
-- Repairs a regression introduced by 0055 earlier in the same session.
--
-- 0055 needed to add reconcile:candidates to sync_health(), and rebuilt the function from the 0039
-- definition to do it. The live function was NOT 0039: it had since been extended (by
-- notes_offlimit_crons_and_health, applied in the database but with no migration file in this repo)
-- to also track history_recent, notes and offlimit. Rebuilding from the older source silently
-- dropped all three - so the feed that writes the entire funnel stopped being monitored at the
-- exact moment we were fixing monitoring.
--
-- Restoring them exposed a second problem. The rule "a live entity whose last_status is outside the
-- known-good set is critical" is what surfaces the error:<msg> rows written by the per-entity
-- try/catch in 0054. But history_recent and notes write free-form progress strings ("pages=3 +300",
-- "cands=60 +altev queue=17285"), which the same rule would pin critical forever. Hence
-- strict_status as a per-entity flag: on for the six pollers, which have a controlled vocabulary;
-- off for the progress-string feeds, which are judged on age alone.
--
-- Also retunes history-recent. The first live run of the queue took 50s for 60 candidates against
-- pg_net's 55s timeout - too close, since a slow RecruitCRM response would push it over. 50
-- candidates at 550ms is ~40s, and running every 3 minutes rather than 5 more than makes up the
-- throughput: 1,000/hour drains the ~17,285 backlog in roughly 17 hours at a sustained 0.28 req/s.
-- With the queue in 0058 this is throughput, not a coverage cap - once the backlog clears each run
-- finds fewer due candidates and returns early.

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
      ('reconcile:candidates','reconcile',1560,3000,false)
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

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'history-recent') then
    perform cron.unschedule('history-recent');
  end if;
  perform cron.schedule(
    'history-recent',
    '*/3 * * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=history_recent&max_candidates=50&sleep_ms=550',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb,
      timeout_milliseconds:=55000);$job$);
end
$do$;
