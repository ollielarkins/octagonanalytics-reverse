-- 0055_reconcile_candidates.sql
-- candidates was the only core entity with no reconcile.
--
-- consultants, clients, jobs and deals all reconcile nightly between 03:00 and 03:30. candidates —
-- 17,326 rows, the largest table we mirror — had none, so anything deleted or merged in RecruitCRM
-- stayed in the mirror indefinitely and the counts drifted.
--
-- It is also what would have swept up the zero-id row that froze the sync on 21/08/2026: that row
-- did not exist upstream, so a reconcile would have soft-deleted it the same night. recruitcrm-sync
-- has supported mode=reconcile&entity=candidates all along; it was simply never scheduled.
--
-- 03:40 keeps the nightly reconciles serialised (consultants 03:00, clients 03:10, jobs 03:20,
-- deals 03:30) so they never contend for the RecruitCRM rate limit. reconcilePaged() has a 200-page
-- cap = 20,000 records, comfortably above the current 17,326, and refuses to reconcile at all on a
-- partial fetch — so an incomplete walk cannot mass-delete.

do $do$
begin
  if exists (select 1 from cron.job where jobname = 'recruitcrm-reconcile-candidates') then
    perform cron.unschedule('recruitcrm-reconcile-candidates');
  end if;
  perform cron.schedule(
    'recruitcrm-reconcile-candidates',
    '40 3 * * *',
    $job$select net.http_post(
      url:='https://kzcmssldvtjnbwwunuwm.supabase.co/functions/v1/recruitcrm-sync?mode=reconcile&entity=candidates',
      headers:=jsonb_build_object('Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imt6Y21zc2xkdnRqbmJ3d3VudXdtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgwNTExMTIsImV4cCI6MjA5MzYyNzExMn0.ptlngXNjvjlEvAhPCiLGFvbRT7nA0zfr4MW-gqtPYRk','Content-Type','application/json'),
      body:='{}'::jsonb,
      timeout_milliseconds:=55000);$job$);
end
$do$;

-- Seed the health row so the new entity does not read as "no sync run on record" (= critical) for
-- the hours between this migration and 03:40. Status text is honest about not having run yet; the
-- reconcile category does not classify on last_status, only on age, so this cannot mask a fault.
insert into public.sync_state (entity, last_run_at, last_status)
values ('reconcile:candidates', now(), 'awaiting first scheduled run')
on conflict (entity) do nothing;

-- Add it to the health classifier on the same thresholds as its peers (26h warn / 50h critical).
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
      ('reconcile:clients','reconcile',1560,3000),
      ('reconcile:jobs','reconcile',1560,3000),
      ('reconcile:deals','reconcile',1560,3000),
      ('reconcile:candidates','reconcile',1560,3000)
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
