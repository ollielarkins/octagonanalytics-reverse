-- 0044_shortlist_in_funnel.sql
-- The Shortlist stage (recruitcrm_stage_id 511685) has been mapped in stage_lookup and recording
-- since 13/02/2025 — 1,595 events to date — but appeared in no funnel, report or dashboard.
-- Surface it as the stage before CV Sent, in the firm funnel, the monthly series and the
-- per-consultant breakdown.
--
-- Caveat for anyone reading the numbers: it is only partially adopted (1,595 shortlist events
-- against 3,361 CV sends), so it is NOT a valid top-of-funnel denominator — a shortlist->CV rate
-- above 100% just means someone skipped the stage.
create or replace function public.dashboard_json()
returns jsonb language sql security definer set search_path = public stable as $function$
  select jsonb_build_object(
    'generated_at', now(),
    'health', (select public.sync_health()),
    'kpis', jsonb_build_object(
      'cv_2026',      (select count(*) from candidate_stage_events where stage_metric='cv_sent' and event_date >= '2026-01-01'),
      'placed_2026',  (select count(*) from candidate_stage_events where stage_metric='placed'  and event_date >= '2026-01-01'),
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
        select stage_metric, count(*) n from candidate_stage_events
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
        from candidate_stage_events where event_date >= (current_date - interval '18 months')
        group by 1) m),
    'consultants', (select jsonb_agg(jsonb_build_object(
          'name',name,'shortlist',sl,'cv_sent',cv,'interview_request',ir,'first_interview',fi,'offered',off,'placed',pl)
          order by cv desc) from (
        select co.name,
          count(*) filter (where e.stage_metric='shortlist') sl,
          count(*) filter (where e.stage_metric='cv_sent') cv,
          count(*) filter (where e.stage_metric='interview_request') ir,
          count(*) filter (where e.stage_metric='first_interview') fi,
          count(*) filter (where e.stage_metric='offered') off,
          count(*) filter (where e.stage_metric='placed') pl
        from candidate_stage_events e
        join jobs j on e.job_slug=j.slug
        join consultants co on j.consultant_id=co.id
        where e.event_date >= '2026-01-01'
        group by co.name
        having count(*) filter (where e.stage_metric='cv_sent') > 0) c),
    'pipeline', (select jsonb_agg(jsonb_build_object('stage',coalesce(deal_stage,'(none)'),'deals',d,'value',v)
          order by v desc) from (
        select deal_stage, count(*) d, coalesce(sum(deal_value),0) v from deals group by deal_stage) p)
  );
$function$;
