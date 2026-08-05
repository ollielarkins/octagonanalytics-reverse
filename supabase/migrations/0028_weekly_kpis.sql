-- 0028_weekly_kpis.sql
-- Weekly per-recruiter targets + a this-week actuals-vs-target report for the Slack
-- /kpis command (team-wide). Targets are loaded by the admin (see README); until then
-- the report shows actuals with a null target.
--
-- Metrics: cv_sent, first_interview, placed (owner-attributed, from the funnel) and
-- calls (attributed to the caller, from call_activity). Week starts Monday.

create table if not exists public.weekly_targets (
  consultant_recruitcrm_id bigint not null,
  metric                   text   not null,   -- cv_sent | calls | first_interview | placed
  weekly_target            numeric not null,
  updated_at               timestamptz not null default now(),
  primary key (consultant_recruitcrm_id, metric)
);
alter table public.weekly_targets enable row level security;
drop policy if exists weekly_targets_read_auth on public.weekly_targets;
create policy weekly_targets_read_auth on public.weekly_targets for select to authenticated using (true);

create or replace function public.kpis_report()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with monday as (select date_trunc('week', current_date)::date d),
  ev as (
    select co.recruitcrm_id rid,
      count(*) filter (where e.stage_metric='cv_sent') cv,
      count(*) filter (where e.stage_metric='first_interview') fi,
      count(*) filter (where e.stage_metric='placed') pl
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    where e.event_date >= (select d from monday)
    group by co.recruitcrm_id
  ),
  cl as (
    select consultant_recruitcrm_id rid, count(*) calls
    from call_activity where call_date >= (select d from monday)
    group by consultant_recruitcrm_id
  ),
  base as (select recruitcrm_id rid, name from consultants where deleted_at is null and active)
  select jsonb_build_object(
    'week_start', (select d from monday),
    'definition', 'This week (from Monday) actuals vs weekly targets. cv_sent/first_interview/placed are owner-attributed (job owner); calls are attributed to the caller. target is null until loaded into weekly_targets.',
    'has_targets', (select count(*) > 0 from weekly_targets),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
       'name', b.name,
       'cv_sent', jsonb_build_object('actual', coalesce(ev.cv,0), 'target', (select weekly_target from weekly_targets t where t.consultant_recruitcrm_id=b.rid and t.metric='cv_sent')),
       'calls', jsonb_build_object('actual', coalesce(cl.calls,0), 'target', (select weekly_target from weekly_targets t where t.consultant_recruitcrm_id=b.rid and t.metric='calls')),
       'first_interview', jsonb_build_object('actual', coalesce(ev.fi,0), 'target', (select weekly_target from weekly_targets t where t.consultant_recruitcrm_id=b.rid and t.metric='first_interview')),
       'placed', jsonb_build_object('actual', coalesce(ev.pl,0), 'target', (select weekly_target from weekly_targets t where t.consultant_recruitcrm_id=b.rid and t.metric='placed'))
       ) order by coalesce(ev.cv,0) desc), '[]'::jsonb)
     from base b left join ev on ev.rid=b.rid left join cl on cl.rid=b.rid)
  );
$function$;

revoke all on function public.kpis_report() from public, anon, authenticated;
grant execute on function public.kpis_report() to service_role;
