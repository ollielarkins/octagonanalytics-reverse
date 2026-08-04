-- 0013_dashboard_json.sql
-- Aggregates the whole dashboard into one jsonb payload (KPIs, funnel, monthly,
-- per-consultant [job-owner attributed], deal pipeline). AGGREGATES ONLY — no
-- candidate PII. SECURITY DEFINER so it reads base tables regardless of RLS;
-- callable only by service_role (the public `dashboard` edge function).

create or replace function public.dashboard_json()
returns jsonb language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'generated_at', now(),
    'kpis', jsonb_build_object(
      'cv_2026',      (select count(*) from candidate_stage_events where stage_metric='cv_sent' and event_date >= '2026-01-01'),
      'placed_2026',  (select count(*) from candidate_stage_events where stage_metric='placed'  and event_date >= '2026-01-01'),
      'candidates',   (select count(distinct candidate_id) from candidate_stage_events),
      'jobs',         (select count(*) from jobs where deleted_at is null),
      'open_jobs',    (select count(*) from jobs where deleted_at is null and status ilike '%open%'),
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
          and stage_metric in ('cv_sent','interview_request','first_interview','second_interview','offered','placed')
        group by stage_metric) f),
    'monthly', (select jsonb_agg(jsonb_build_object(
          'month', to_char(ms,'YYYY-MM'),'cv_sent',cv,'interview_request',ir,'first_interview',fi,
          'second_interview',si,'offered',off,'placed',pl) order by ms) from (
        select date_trunc('month',event_date) ms,
          count(*) filter (where stage_metric='cv_sent') cv,
          count(*) filter (where stage_metric='interview_request') ir,
          count(*) filter (where stage_metric='first_interview') fi,
          count(*) filter (where stage_metric='second_interview') si,
          count(*) filter (where stage_metric='offered') off,
          count(*) filter (where stage_metric='placed') pl
        from candidate_stage_events where event_date >= (current_date - interval '18 months')
        group by 1) m),
    'consultants', (select jsonb_agg(jsonb_build_object(
          'name',name,'cv_sent',cv,'interview_request',ir,'first_interview',fi,'offered',off,'placed',pl)
          order by cv desc) from (
        select co.name,
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
$$;

revoke all on function public.dashboard_json() from public, anon, authenticated;
grant execute on function public.dashboard_json() to service_role;

-- The public `dashboard` edge function (verify_jwt=false) renders this payload as
-- HTML server-side on each request. Source: supabase/functions/dashboard/index.ts.
