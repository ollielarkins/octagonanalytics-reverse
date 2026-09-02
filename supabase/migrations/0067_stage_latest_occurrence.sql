-- 0067_stage_latest_occurrence.sql
-- Count a candidate-job pair once per stage, at the LAST time it entered that stage.
--
-- RecruitCRM's candidate lifecycle report shows one row per candidate-job-stage, dated at the most
-- recent entry into that stage. We were counting the pair in every month it ever entered, so a
-- candidate rejected by the client in November 2025 and again in June 2026 appeared in both months
-- for us and only in June for them.
--
-- That is the exact shape of the residual we chased all day: one-directional (we could only ever be
-- higher), concentrated in the busiest stages (more re-entries), and zero for the current week
-- (nothing re-entered yet).
--
-- Found by narrowing a 2-row gap in November Rejected-Client to one consultant, then to two
-- candidate-job pairs, then noticing both had a second, later event on the same job:
--   Anthonia Ononogbo,  Application Scientist - rejected 11/11/2025 and again 24/06/2026
--   Khuram Walayat,     Application Scientist - rejected 24/11/2025 and again 01/12/2025
--
-- Verified on two months before implementing. November went 8 of 10 stages exact (Rejected-Client
-- 146->144, Rejected-Consultant 343->342); January closed Rejected-Consultant 783->777 and CV Sent
-- 345->342, and no stage that already matched was broken.
--
-- Consequence worth understanding: a historical figure becomes mutable. Re-entering a stage moves
-- that pair out of the older month into the newer one, so last month's number can change. That is
-- RecruitCRM's behaviour and matching it is the point - but it means a funnel figure quoted in a
-- report is a snapshot, not a permanent fact.
--
-- candidate_stage_events remains the full event log; this view is only the reporting grain.
--
-- Applied on 02/09/2026 as two migrations (stage_latest_occurrence_view, dashboard_uses_stage_latest);
-- combined here as one replayable file.

create or replace view public.candidate_stage_latest as
select distinct on (candidate_slug, job_slug, stage_metric)
  candidate_slug, job_slug, candidate_id, candidate_name,
  job_id, job_title, stage_metric, stage_name,
  event_date, event_timestamp, consultant_id, consultant
from public.candidate_stage_events
order by candidate_slug, job_slug, stage_metric, event_timestamp desc;

comment on view public.candidate_stage_latest is
  'One row per candidate-job-stage at its most recent occurrence, with that occurrence''s actor. This is the grain RecruitCRM''s candidate lifecycle report uses; candidate_stage_events remains the full event log.';

revoke all on public.candidate_stage_latest from anon, authenticated;
grant select on public.candidate_stage_latest to service_role;

create or replace function public.funnel_report(
  p_from date default '2026-01-01',
  p_to   date default '2100-01-01',
  p_consultant text default null,
  p_team text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with e as (
    select coalesce(co.name, ev.consultant) as consultant, co.team, ev.stage_metric
    from candidate_stage_latest ev
    join jobs j on ev.job_slug = j.slug and j.deleted_at is null
    left join consultants co on co.recruitcrm_id = ev.consultant_id
    where ev.event_date >= p_from and ev.event_date < p_to
      and (p_consultant is null or coalesce(co.name, ev.consultant) ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
  ),
  per as (
    select consultant,
      count(*) filter (where stage_metric='cv_sent') cv,
      count(*) filter (where stage_metric='interview_request') ir,
      count(*) filter (where stage_metric='first_interview') fi,
      count(*) filter (where stage_metric='second_interview') si,
      count(*) filter (where stage_metric='third_interview') ti,
      count(*) filter (where stage_metric='offered') off,
      count(*) filter (where stage_metric='placed') pl
    from e where consultant is not null group by consultant
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_build_object('consultant', p_consultant, 'team', p_team),
    'definition', 'Candidate-job pairs reaching each stage, counted once at the LAST time they entered it and credited to whoever made that move. This is the grain RecruitCRM''s candidate lifecycle report uses. Percentages are shares of CVs sent.',
    'totals', (select jsonb_build_object(
        'cv_sent', coalesce(sum(cv),0), 'interview_request', coalesce(sum(ir),0),
        'first_interview', coalesce(sum(fi),0), 'second_interview', coalesce(sum(si),0),
        'third_interview', coalesce(sum(ti),0),
        'offered', coalesce(sum(off),0), 'placed', coalesce(sum(pl),0),
        'cv_to_interview_pct', round(sum(ir)::numeric/nullif(sum(cv),0),3),
        'cv_to_first_interview_pct', round(sum(fi)::numeric/nullif(sum(cv),0),3),
        'first_interview_to_offer_pct', round(sum(off)::numeric/nullif(sum(fi),0),3),
        'cv_to_placed_pct', round(sum(pl)::numeric/nullif(sum(cv),0),3)) from per),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'cv_sent', cv, 'interview_request', ir, 'first_interview', fi,
        'second_interview', si, 'third_interview', ti, 'offered', off, 'placed', pl,
        'cv_to_first_interview_pct', round(fi::numeric/nullif(cv,0),3),
        'cv_to_placed_pct', round(pl::numeric/nullif(cv,0),3)) order by cv desc), '[]'::jsonb) from per)
  );
$function$;

create or replace function public.kpis_report()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with monday as (select date_trunc('week', current_date)::date d),
  ev as (
    select e.consultant_id rid,
      count(*) filter (where e.stage_metric='cv_sent') cv,
      count(*) filter (where e.stage_metric='interview_request') ir,
      count(*) filter (where e.stage_metric='first_interview') fi,
      count(*) filter (where e.stage_metric='placed') pl
    from candidate_stage_latest e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    where e.event_date >= (select d from monday)
    group by e.consultant_id
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
    'definition', 'This week (from Monday) actuals vs weekly targets. cv_sent/interview_request/first_interview/placed count candidate-job pairs once at the LAST time they entered the stage, credited to whoever made that move - the grain RecruitCRM uses. bd_calls/client_calls are attributed to the caller and count only categorised Devyce calls, so they undercount until calls are tagged. placed has no weekly target (billing is quarterly).',
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

create or replace function public.consultant_leaderboard(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_metric text default 'placed', p_limit integer default 20)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with per as (
    select coalesce(co.name, e.consultant) consultant,
      count(*) filter (where e.stage_metric='cv_sent') cv,
      count(*) filter (where e.stage_metric='first_interview') fi,
      count(*) filter (where e.stage_metric='placed') pl
    from candidate_stage_latest e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    left join consultants co on co.recruitcrm_id = e.consultant_id
    where e.event_date >= p_from and e.event_date < p_to
      and coalesce(co.name, e.consultant) is not null
    group by coalesce(co.name, e.consultant)
  ),
  ranked as (
    select consultant, cv, fi, pl,
      case when p_metric='cv_sent' then cv when p_metric='first_interview' then fi else pl end as sortval
    from per order by sortval desc, cv desc limit p_limit
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from',p_from,'to',p_to),
    'ranked_by', p_metric,
    'definition','Consultants ranked by the chosen metric, counting candidate-job pairs once at the LAST time they entered the stage and credited to whoever made that move.',
    'leaderboard', (select coalesce(jsonb_agg(jsonb_build_object(
       'name',consultant,'cv_sent',cv,'first_interview',fi,'placed',pl,
       'cv_to_placed_pct',round(pl::numeric/nullif(cv,0),3)) order by sortval desc, cv desc), '[]'::jsonb) from ranked)
  );
$function$;

create or replace function public.dashboard_json()
returns jsonb language sql security definer set search_path = public stable as $function$
  select jsonb_build_object(
    'generated_at', now(),
    'health', (select public.sync_health()),
    'kpis', jsonb_build_object(
      'cv_2026',      (select count(*) from candidate_stage_latest where stage_metric='cv_sent' and event_date >= '2026-01-01'),
      'placed_2026',  (select count(*) from candidate_stage_latest where stage_metric='placed'  and event_date >= '2026-01-01'),
      'candidates',   (select count(distinct candidate_id) from candidate_stage_events),
      'candidates_in_pipeline', (select count(distinct candidate_id) from candidate_stage_events),
      'candidates_total',       (select count(*) from candidates where deleted_at is null),
      'jobs',         (select count(*) from jobs where deleted_at is null),
      'open_jobs',    (select count(*) from jobs where deleted_at is null and status ilike '%open%'),
      'jobs_no_client',(select count(*) from jobs where deleted_at is null and client_id is null),
      'clients',      (select count(*) from clients where deleted_at is null),
      'consultants',  (select count(*) from consultants where deleted_at is null),
      'open_pipeline',(select coalesce(sum(deal_value),0) from deals where deal_stage not in ('Won','Lost')),
      'won',          (select coalesce(sum(deal_value),0) from deals where deal_stage='Won'),
      'cv_all',       (select count(*) from candidate_stage_latest where stage_metric='cv_sent'),
      'placed_all',   (select count(*) from candidate_stage_latest where stage_metric='placed')
    ),
    'funnel', (select jsonb_object_agg(stage_metric, n) from (
        select stage_metric, count(*) n from candidate_stage_latest
        where event_date >= '2026-01-01'
          and stage_metric in ('shortlist','cv_sent','interview_request','first_interview','second_interview','third_interview','offered','placed')
        group by stage_metric) f),
    'monthly', (select jsonb_agg(jsonb_build_object(
          'month', to_char(ms,'YYYY-MM'),'shortlist',sl,'cv_sent',cv,'interview_request',ir,'first_interview',fi,
          'second_interview',si,'third_interview',ti,'offered',off,'placed',pl) order by ms) from (
        select date_trunc('month',event_date) ms,
          count(*) filter (where stage_metric='shortlist') sl,
          count(*) filter (where stage_metric='cv_sent') cv,
          count(*) filter (where stage_metric='interview_request') ir,
          count(*) filter (where stage_metric='first_interview') fi,
          count(*) filter (where stage_metric='second_interview') si,
          count(*) filter (where stage_metric='third_interview') ti,
          count(*) filter (where stage_metric='offered') off,
          count(*) filter (where stage_metric='placed') pl
        from candidate_stage_latest where event_date >= (current_date - interval '18 months')
        group by 1) m),
    'consultants', (select jsonb_agg(jsonb_build_object(
          'name',name,'shortlist',sl,'cv_sent',cv,'interview_request',ir,'first_interview',fi,'offered',off,'placed',pl)
          order by cv desc) from (
        select coalesce(co.name, e.consultant) as name,
          count(*) filter (where e.stage_metric='shortlist') sl,
          count(*) filter (where e.stage_metric='cv_sent') cv,
          count(*) filter (where e.stage_metric='interview_request') ir,
          count(*) filter (where e.stage_metric='first_interview') fi,
          count(*) filter (where e.stage_metric='offered') off,
          count(*) filter (where e.stage_metric='placed') pl
        from candidate_stage_latest e
        join jobs j on e.job_slug=j.slug and j.deleted_at is null
        left join consultants co on co.recruitcrm_id = e.consultant_id
        where e.event_date >= '2026-01-01' and coalesce(co.name, e.consultant) is not null
        group by coalesce(co.name, e.consultant)
        having count(*) filter (where e.stage_metric='cv_sent') > 0) c),
    'pipeline', (select jsonb_agg(jsonb_build_object('stage',coalesce(deal_stage,'(none)'),'deals',d,'value',v)
          order by v desc) from (
        select deal_stage, count(*) d, coalesce(sum(deal_value),0) v from deals group by deal_stage) p)
  );
$function$;
