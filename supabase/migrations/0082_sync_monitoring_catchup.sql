-- 0082_sync_monitoring_catchup.sql
-- ALREADY LIVE in production (applied from chat on 25/09/2026). Commit so the repo matches.
-- Idempotent: safe to re-run.
--   * sync_health(): one failed live run = warn, not critical; live critical 30 -> 45 min;
--     backfill:candidates thresholds sized for a twice-daily pass.
--   * backfill-candidates-pass: hourly -> 06:40 / 19:40 BST (05:40 / 18:40 UTC).

CREATE OR REPLACE FUNCTION public.sync_health()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cfg(entity, category, warn_min, crit_min, strict_status) as (
    values
      ('candidates','live',20,45,true),
      ('clients','live',20,45,true),
      ('consultants','live',20,45,true),
      ('jobs','live',20,45,true),
      ('calls','live',20,45,true),
      ('deals','live',20,45,true),
      ('history_recent','live',25,60,false),
      ('notes','live',25,60,false),
      ('offlimit','reconcile',1560,3000,false),
      ('reconcile:clients','reconcile',120,240,false),
      ('reconcile:jobs','reconcile',120,240,false),
      ('reconcile:deals','reconcile',120,240,false),
      ('backfill:candidates','reconcile',840,1080,false)
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
        -- An error only goes critical once the next scheduled run has also failed to succeed.
        when strict_status and last_status is not null
             and last_status not in (select status from good)
             and mins >= warn_min then 'critical'
        when mins >= crit_min then 'critical'
        -- A single failed run that has not yet had a chance to retry: warn, no Slack alert.
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'warn'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when last_run_at is null then 'no sync run on record'
        when strict_status and last_status is not null
             and last_status not in (select status from good)
             and mins >= warn_min then 'error status: '||last_status
        when mins >= crit_min then 'stale: '||mins||' min since last run'
        when strict_status and last_status is not null
             and last_status not in (select status from good) then 'error status (retrying): '||last_status
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

select cron.alter_job(job_id := (select jobid from cron.job where jobname = 'backfill-candidates-pass'),
                      schedule := '40 5,18 * * *');
update cron_manifest set schedule = '40 5,18 * * *',
       note = 'STARTS a candidates deletion pass (0063). Twice daily outside working hours (25/09/2026) - hourly pass collided with incrementals.'
 where jobname = 'backfill-candidates-pass';
