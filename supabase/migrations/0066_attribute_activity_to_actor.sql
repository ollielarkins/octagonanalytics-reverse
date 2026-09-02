-- 0066_attribute_activity_to_actor.sql
-- Attribute funnel activity to whoever moved the stage, not the job owner.
--
-- Verified against RecruitCRM's January report: on actor attribution 20 of the 27 per-consultant
-- figures matched exactly, and 7 of 9 on CV Sent. On job owner they scattered - Keelan 184 against
-- their 105, Chloe 160 against their 217. Those two offsets alone were 136 rows in opposite
-- directions, which cancelled in the monthly totals. That is why every total looked within 1% while
-- the per-person numbers were wrong: the errors hid each other.
--
-- Job-owner attribution also invented activity for people who were not there. Georgia Cook showed 7
-- January CV sends despite zero actions that month, because she later inherited those jobs.
--
-- Departed consultants are NOT excluded - RecruitCRM includes them (Dale matched exactly at 30) -
-- so the consultants join is a LEFT JOIN falling back to the denormalised actor name on the event.
--
-- Also switches kpis_report and consultant_leaderboard to distinct candidate-job pairs, which 0065
-- had already done for the funnel.
--
-- Scope is deliberately activity metrics only. cold_jobs, stalled_report, time_to_fill,
-- placements_report and rejection_report stay owner-attributed: they answer "whose desk is this",
-- not "who did this".
--
-- NOTE: this contradicts the standing org instruction "funnel attributed to job owner". That
-- instruction is now out of date and needs updating in the admin settings - decided 02/09/2026.

create or replace function public.funnel_report(
  p_from date default '2026-01-01',
  p_to   date default '2100-01-01',
  p_consultant text default null,
  p_team text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with e as (
    select coalesce(co.name, ev.consultant) as consultant, co.team, ev.stage_metric,
           ev.candidate_slug||'|'||ev.job_slug as pair
    from candidate_stage_events ev
    join jobs j on ev.job_slug = j.slug and j.deleted_at is null
    left join consultants co on co.recruitcrm_id = ev.consultant_id
    where ev.event_date >= p_from and ev.event_date < p_to
      and (p_consultant is null or coalesce(co.name, ev.consultant) ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
  ),
  per as (
    select consultant,
      count(distinct pair) filter (where stage_metric='cv_sent') cv,
      count(distinct pair) filter (where stage_metric='interview_request') ir,
      count(distinct pair) filter (where stage_metric='first_interview') fi,
      count(distinct pair) filter (where stage_metric='second_interview') si,
      count(distinct pair) filter (where stage_metric='third_interview') ti,
      count(distinct pair) filter (where stage_metric='offered') off,
      count(distinct pair) filter (where stage_metric='placed') pl
    from e where consultant is not null group by consultant
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_build_object('consultant', p_consultant, 'team', p_team),
    'definition', 'Distinct candidate-job pairs reaching each stage within [from, to), credited to the consultant who MOVED the stage. A pair counts once per stage however many times it moved there. This matches RecruitCRM''s own reports on both counts. Percentages are shares of CVs sent.',
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
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent') cv,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='interview_request') ir,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview') fi,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='placed') pl
    from candidate_stage_events e
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
    'definition', 'This week (from Monday) actuals vs weekly targets. cv_sent/interview_request/first_interview/placed count distinct candidate-job pairs and are credited to the consultant who MOVED the stage, matching RecruitCRM. bd_calls/client_calls are attributed to the caller and count only categorised Devyce calls (custom_call_type), so they undercount until calls are tagged. placed has no weekly target (billing is quarterly). target is null where none is loaded.',
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
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent') cv,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview') fi,
      count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='placed') pl
    from candidate_stage_events e
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
    'definition','Consultants ranked by the chosen metric (placed|cv_sent|first_interview), counting distinct candidate-job pairs and credited to whoever MOVED the stage, within [from,to).',
    'leaderboard', (select coalesce(jsonb_agg(jsonb_build_object(
       'name',consultant,'cv_sent',cv,'first_interview',fi,'placed',pl,
       'cv_to_placed_pct',round(pl::numeric/nullif(cv,0),3)) order by sortval desc, cv desc), '[]'::jsonb) from ranked)
  );
$function$;
