-- 0029_kpis_expand.sql
-- Expand the weekly KPI scorecard to match Octagon's actual weekly minimums, and load
-- the firm-wide targets. Supersedes the metric set in 0028.
--
-- Weekly KPIs (owner-attributed for funnel metrics; caller-attributed for calls; week from Monday):
--   cv_sent=10, interview_request=5, first_interview=4, bd_calls=5, client_calls=5.
--   placed is reported for visibility but has no weekly target (billing is quarterly).
--
-- Call split uses RecruitCRM/Devyce custom_call_type:
--   bd_calls     = 'Contact - Prospect (BD)'
--   client_calls = 'Contact - Client' + 'Contact - Client Info'
-- NOTE: most calls are currently uncategorised (custom_call_type null); bd/client counts
-- only include categorised calls, so they undercount until consultants tag calls in Devyce.

create or replace function public.kpis_report()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with monday as (select date_trunc('week', current_date)::date d),
  ev as (
    select co.recruitcrm_id rid,
      count(*) filter (where e.stage_metric='cv_sent') cv,
      count(*) filter (where e.stage_metric='interview_request') ir,
      count(*) filter (where e.stage_metric='first_interview') fi,
      count(*) filter (where e.stage_metric='placed') pl
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    where e.event_date >= (select d from monday)
    group by co.recruitcrm_id
  ),
  cl as (
    select consultant_recruitcrm_id rid,
      count(*) filter (where custom_call_type = 'Contact - Prospect (BD)') bd,
      count(*) filter (where custom_call_type in ('Contact - Client','Contact - Client Info')) cc
    from call_activity where call_date >= (select d from monday)
    group by consultant_recruitcrm_id
  ),
  base as (select recruitcrm_id rid, name from consultants where deleted_at is null and active),
  tgt as (select metric, weekly_target, consultant_recruitcrm_id from weekly_targets)
  select jsonb_build_object(
    'week_start', (select d from monday),
    'definition', 'This week (from Monday) actuals vs weekly targets. cv_sent/interview_request/first_interview/placed are owner-attributed (job owner). bd_calls/client_calls are attributed to the caller and count only categorised Devyce calls (custom_call_type), so they undercount until calls are tagged. placed has no weekly target (billing is quarterly). target is null where none is loaded.',
    'has_targets', (select count(*) > 0 from weekly_targets),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
       'name', b.name,
       'cv_sent',          jsonb_build_object('actual', coalesce(ev.cv,0), 'target', (select weekly_target from tgt where tgt.consultant_recruitcrm_id=b.rid and tgt.metric='cv_sent')),
       'interview_request',jsonb_build_object('actual', coalesce(ev.ir,0), 'target', (select weekly_target from tgt where tgt.consultant_recruitcrm_id=b.rid and tgt.metric='interview_request')),
       'first_interview',  jsonb_build_object('actual', coalesce(ev.fi,0), 'target', (select weekly_target from tgt where tgt.consultant_recruitcrm_id=b.rid and tgt.metric='first_interview')),
       'bd_calls',         jsonb_build_object('actual', coalesce(cl.bd,0), 'target', (select weekly_target from tgt where tgt.consultant_recruitcrm_id=b.rid and tgt.metric='bd_calls')),
       'client_calls',     jsonb_build_object('actual', coalesce(cl.cc,0), 'target', (select weekly_target from tgt where tgt.consultant_recruitcrm_id=b.rid and tgt.metric='client_calls')),
       'placed',           jsonb_build_object('actual', coalesce(ev.pl,0), 'target', (select weekly_target from tgt where tgt.consultant_recruitcrm_id=b.rid and tgt.metric='placed'))
       ) order by coalesce(ev.cv,0) desc), '[]'::jsonb)
     from base b left join ev on ev.rid=b.rid left join cl on cl.rid=b.rid)
  );
$function$;

revoke all on function public.kpis_report() from public, anon, authenticated;
grant execute on function public.kpis_report() to service_role;

-- Load firm-wide weekly targets for every active consultant (idempotent).
insert into public.weekly_targets (consultant_recruitcrm_id, metric, weekly_target)
select c.recruitcrm_id, m.metric, m.target
from public.consultants c
cross join (values
  ('cv_sent', 10),
  ('interview_request', 5),
  ('first_interview', 4),
  ('bd_calls', 5),
  ('client_calls', 5)
) as m(metric, target)
where c.deleted_at is null and c.active and c.recruitcrm_id is not null
on conflict (consultant_recruitcrm_id, metric) do update set weekly_target = excluded.weekly_target, updated_at = now();
