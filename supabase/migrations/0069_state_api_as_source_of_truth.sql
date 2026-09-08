-- 0069_state_api_as_source_of_truth.sql
-- Correct the definition strings. No counting logic changes - the arithmetic in 0065-0067 stands.
--
-- Those definitions told the reader the numbers are "the grain RecruitCRM's candidate lifecycle
-- report uses". Row-level reconciliation on 08/09/2026 showed that is not quite true, and a
-- definition that overstates its own accuracy is worse than one that admits a bound.
--
-- The proof case: JONATHAN KANE (candidate 43879) on job "Embedded Software Engineer", shortlisted
-- 20/01/2026 14:23 by Shammi Choudhury. The API returns that event. RecruitCRM's own January
-- Shortlist report does not list it. The candidate is live, single, not merged and not deleted;
-- 77 other pairs share every structural property with it and ARE on the report. Every candidate
-- exclusion rule was tested and falsified - dwell time (breaks Interview Request and 1st Interview,
-- both currently exact), stage re-entry (Jennifer and Steve re-enter and still match), crediting the
-- last actor (materially worse), and "progressed in a later month" (78 pairs match, 77 are counted).
--
-- So the gap is between RecruitCRM's API and RecruitCRM's report layer, not between RecruitCRM and
-- us. Decision taken with Ollie on 08/09/2026: the API is the system of truth. We do not add
-- per-row exclusions to chase the last 0.4% - every rule that closed it broke a stage that is
-- currently exact, which is fitting noise.
--
-- Measured position at the time of writing, distinct pairs at latest occurrence, actor-attributed:
--   34 of 50 stage-months exact; total absolute variance 30 rows in 7,935 (0.4%)
--   Offered / Placed / 2nd Interview / 3rd Interview exact in all five months (20 of 20)
--   Residual confined to Shortlist, CV Sent, Rejected - Consultant
--
-- Anyone tempted to "fix" the remaining variance should read octagon-funnel-parity-limit first.

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
    'definition', 'Candidate-job pairs reaching each stage, counted once at the LAST time they entered it and credited to whoever made that move. Source of truth is the RecruitCRM API (/candidates/{slug}/history), NOT the candidate lifecycle report. The two agree on 34 of 50 stage-months tested across Nov 2025 and Jan/Mar/Jul/Aug 2026, and are exact on Offered, Placed, 2nd and 3rd Interview in every month. Residual divergence is ~0.4% (30 rows in 7,935), confined to Shortlist, CV Sent and Rejected - Consultant, and is caused by the report omitting rows the API returns. Percentages are shares of CVs sent.',
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
    'definition', 'This week (from Monday) actuals vs weekly targets. cv_sent/interview_request/first_interview/placed count candidate-job pairs once at the LAST time they entered the stage, credited to whoever made that move, per the RecruitCRM API rather than its lifecycle report (see funnel_report definition). bd_calls/client_calls are attributed to the caller and count only categorised Devyce calls, so they undercount until calls are tagged. placed has no weekly target (billing is quarterly).',
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
    'definition','Consultants ranked by the chosen metric, counting candidate-job pairs once at the LAST time they entered the stage and credited to whoever made that move. Counted from the RecruitCRM API, not its lifecycle report (see funnel_report definition).',
    'leaderboard', (select coalesce(jsonb_agg(jsonb_build_object(
       'name',consultant,'cv_sent',cv,'first_interview',fi,'placed',pl,
       'cv_to_placed_pct',round(pl::numeric/nullif(cv,0),3)) order by sortval desc, cv desc), '[]'::jsonb) from ranked)
  );
$function$;
