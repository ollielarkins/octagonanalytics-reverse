-- 0124_sync_consecutive_failures.sql
-- Only 2 of the 6 candidates-sync timeouts on 25-28/10/2026 alerted. sync_health() judged each feed
-- on its latest status alone, and only for strict feeds, so a failure in history_recent or
-- backfill:candidates never went critical, and history_recent did not record its errors at all
-- (fixed in recruitcrm-sync alongside this).
--
-- sync_state now counts consecutive 'error:' statuses per feed. Two or more in a row is critical for
-- every feed, strict or not. A single failure still only warns. Every other branch is unchanged,
-- copied from the live definition on 28/10/2026.

alter table public.sync_state add column if not exists error_count int not null default 0;

create or replace function public.sync_state_count_errors()
returns trigger language plpgsql set search_path = public, pg_temp
as $function$
begin
  if new.last_status like 'error:%' then
    new.error_count := case when tg_op = 'INSERT' then 1 else coalesce(old.error_count, 0) + 1 end;
  else
    new.error_count := 0;
  end if;
  return new;
end;
$function$;

drop trigger if exists sync_state_count_errors on public.sync_state;
create trigger sync_state_count_errors
  before insert or update of last_status on public.sync_state
  for each row execute function public.sync_state_count_errors();

create or replace function public.sync_health()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
      ('meetings','live',25,60,false),
      ('offlimit','reconcile',120,240,false),
      ('reconcile:clients','reconcile',120,240,false),
      ('reconcile:jobs','reconcile',120,240,false),
      ('reconcile:deals','reconcile',120,240,false),
      ('backfill:candidates','reconcile',840,1080,false)
  ),
  good(status) as (values ('ok'),('caught_up'),('complete'),('resume_next_page')),
  ev as (
    select c.entity, c.category, c.warn_min, c.crit_min, c.strict_status,
           s.last_run_at, s.last_status, coalesce(s.error_count, 0) as error_count,
           round(extract(epoch from (now()-s.last_run_at))/60)::int as mins
    from cfg c left join sync_state s on s.entity = c.entity
  ),
  cls as (
    select entity, category, last_run_at, last_status, mins, error_count,
      case
        -- 0124: two or more failed runs in a row, on any feed.
        when error_count >= 2 then 'critical'
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
        when error_count >= 2 then 'failing: '||error_count||' runs in a row - '||last_status
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
        'minutes_stale', mins, 'last_status', last_status, 'error_count', error_count,
        'status', status, 'reason', reason)
        order by (status='critical') desc, (status='warn') desc, entity) from cls)
  );
$function$;
