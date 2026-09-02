-- 0065_funnel_counts_distinct_pairs.sql
-- Count each candidate-job pair once per stage, not once per stage MOVE.
--
-- candidate_stage_events is an event log: a candidate bounced back to a stage, or re-shortlisted on
-- the same job, writes another row. Every funnel figure used count(*), so it counted the moves.
-- RecruitCRM's own reports count the pair. That made us structurally high on every stage - 2026 YTD:
-- Shortlist +138, Rejected-Consultant +119, CV Sent +56, 1st Interview +55.
--
-- Verified against RecruitCRM's report for two independent months. On distinct pairs, July matched
-- 4 of 10 stages exactly and August 7 of 10, the rest within 0.8%. On raw events nothing matched.
-- July is the stronger test: events and pairs diverge by 38 rows there, so a wrong basis could not
-- have landed close by luck.
--
-- Placed is unaffected either way - nobody is placed twice on the same job - so billing and
-- placement counts do not move. Everything else drops slightly; that is a correction, not a decline.
--
-- Applied via apply_migration on 02/09/2026; this file is the replayable record.

create or replace function public.funnel_report(
  p_from date default '2026-01-01',
  p_to   date default '2100-01-01',
  p_consultant text default null,
  p_team text default null
)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with e as (
    select co.name as consultant, co.team, ev.stage_metric,
           ev.candidate_slug||'|'||ev.job_slug as pair
    from candidate_stage_events ev
    join jobs j on ev.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    where ev.event_date >= p_from and ev.event_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
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
    from e group by consultant
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_build_object('consultant', p_consultant, 'team', p_team),
    'definition', 'Distinct candidate-job pairs reaching each stage within [from, to), credited to the owning consultant of each job. A pair counts once per stage however many times it moved there, which is how RecruitCRM reports it. Percentages are shares of CVs sent.',
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


create or replace function public.dashboard_json()
returns jsonb language sql security definer set search_path = public stable as $function$
  select jsonb_build_object(
    'generated_at', now(),
    'health', (select public.sync_health()),
    'kpis', jsonb_build_object(
      'cv_2026',      (select count(distinct candidate_slug||'|'||job_slug) from candidate_stage_events where stage_metric='cv_sent' and event_date >= '2026-01-01'),
      'placed_2026',  (select count(distinct candidate_slug||'|'||job_slug) from candidate_stage_events where stage_metric='placed'  and event_date >= '2026-01-01'),
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
      'cv_all',       (select count(*) from candidate_stage_events where stage_metric='cv_sent'),
      'placed_all',   (select count(*) from candidate_stage_events where stage_metric='placed')
    ),
    'funnel', (select jsonb_object_agg(stage_metric, n) from (
        select stage_metric, count(distinct candidate_slug||'|'||job_slug) n from candidate_stage_events
        where event_date >= '2026-01-01'
          and stage_metric in ('shortlist','cv_sent','interview_request','first_interview','second_interview','third_interview','offered','placed')
        group by stage_metric) f),
    'monthly', (select jsonb_agg(jsonb_build_object(
          'month', to_char(ms,'YYYY-MM'),'shortlist',sl,'cv_sent',cv,'interview_request',ir,'first_interview',fi,
          'second_interview',si,'third_interview',ti,'offered',off,'placed',pl) order by ms) from (
        select date_trunc('month',event_date) ms,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='shortlist') sl,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='cv_sent') cv,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='interview_request') ir,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='first_interview') fi,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='second_interview') si,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='third_interview') ti,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='offered') off,
          count(distinct candidate_slug||'|'||job_slug) filter (where stage_metric='placed') pl
        from candidate_stage_events where event_date >= (current_date - interval '18 months')
        group by 1) m),
    'consultants', (select jsonb_agg(jsonb_build_object(
          'name',name,'shortlist',sl,'cv_sent',cv,'interview_request',ir,'first_interview',fi,'offered',off,'placed',pl)
          order by cv desc) from (
        select co.name,
          count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='shortlist') sl,
          count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent') cv,
          count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='interview_request') ir,
          count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='first_interview') fi,
          count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='offered') off,
          count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='placed') pl
        from candidate_stage_events e
        join jobs j on e.job_slug=j.slug
        join consultants co on j.consultant_id=co.id
        where e.event_date >= '2026-01-01'
        group by co.name
        having count(distinct e.candidate_slug||'|'||e.job_slug) filter (where e.stage_metric='cv_sent') > 0) c),
    'pipeline', (select jsonb_agg(jsonb_build_object('stage',coalesce(deal_stage,'(none)'),'deals',d,'value',v)
          order by v desc) from (
        select deal_stage, count(*) d, coalesce(sum(deal_value),0) v from deals group by deal_stage) p)
  );
$function$;
