-- 0039_health_covers_calls_and_deals.sql
-- sync_health() only classified candidates/clients/consultants/jobs plus the two nightly
-- reconciles, but the incremental sync has since gained 'calls' (Devyce telephony, 0027) and
-- 'deals' (billing, v3.13.0), and 0035 added a nightly 'reconcile:deals'. All three were syncing
-- untracked: if the Devyce call feed stalled, the dashboard would still report "sync healthy"
-- while BD/client call KPIs quietly fell to zero — exactly the silent-stall failure 0015 exists
-- to prevent. Same category thresholds as their peers (live 10/30 min, reconcile 26h/50h).
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
      ('reconcile:clients','reconcile',1560,3000),  -- 26h warn / 50h critical
      ('reconcile:jobs','reconcile',1560,3000),
      ('reconcile:deals','reconcile',1560,3000)
  ),
  good(status) as (values ('ok'),('caught_up'),('complete'),('resume_next_page')),
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
             and last_status not in (select status from good) then 'critical'
        when mins >= crit_min then 'critical'
        when mins >= warn_min then 'warn'
        else 'ok'
      end as status,
      case
        when last_run_at is null then 'no sync run on record'
        when category='live' and last_status is not null
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
