-- 0014_funnel_report.sql
-- The read-side reporting function behind the MCP `funnel_report` tool (M5).
--
-- Returns the hiring-stage funnel as a single jsonb document: firm-wide totals
-- with conversion ratios, plus a per-consultant breakdown. Every figure is
-- derived from candidate_stage_events (D1) and credited to the OWNING consultant
-- of each job (owner attribution) — never `updated_by` — because updated_by
-- attribution produced impossible funnels (one consultant credited with another's
-- CVs). Percentages are shares of CVs sent. Soft-deleted jobs/consultants excluded.
--
-- Window is half-open [from, to). Defaults: from 2026-01-01 (the reliable logging
-- window) to the far future. Optional consultant (ILIKE) and exact-team filters.
--
-- SECURITY DEFINER: callable by the MCP function's role without granting it broad
-- table rights; search_path pinned to public.

create or replace function public.funnel_report(
  p_from date default '2026-01-01',
  p_to   date default '2100-01-01',
  p_consultant text default null,
  p_team text default null
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with e as (
    select co.name as consultant, co.team, ev.stage_metric
    from candidate_stage_events ev
    join jobs j on ev.job_slug = j.slug and j.deleted_at is null
    join consultants co on j.consultant_id = co.id and co.deleted_at is null
    where ev.event_date >= p_from and ev.event_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
      and (p_team is null or co.team = p_team)
  ),
  per as (
    select consultant,
      count(*) filter (where stage_metric='cv_sent') cv,
      count(*) filter (where stage_metric='interview_request') ir,
      count(*) filter (where stage_metric='first_interview') fi,
      count(*) filter (where stage_metric='second_interview') si,
      count(*) filter (where stage_metric='offered') off,
      count(*) filter (where stage_metric='placed') pl
    from e group by consultant
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'filters', jsonb_build_object('consultant', p_consultant, 'team', p_team),
    'definition', 'Funnel events from candidate_stage_events, credited to the owning consultant of each job, within [from, to). Percentages are shares of CVs sent. This is what RecruitCRM has logged as hiring-stage moves.',
    'totals', (select jsonb_build_object(
        'cv_sent', coalesce(sum(cv),0), 'interview_request', coalesce(sum(ir),0),
        'first_interview', coalesce(sum(fi),0), 'second_interview', coalesce(sum(si),0),
        'offered', coalesce(sum(off),0), 'placed', coalesce(sum(pl),0),
        'cv_to_interview_pct', round(sum(ir)::numeric/nullif(sum(cv),0),3),
        'cv_to_first_interview_pct', round(sum(fi)::numeric/nullif(sum(cv),0),3),
        'first_interview_to_offer_pct', round(sum(off)::numeric/nullif(sum(fi),0),3),
        'cv_to_placed_pct', round(sum(pl)::numeric/nullif(sum(cv),0),3)) from per),
    'consultants', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'cv_sent', cv, 'interview_request', ir, 'first_interview', fi,
        'second_interview', si, 'offered', off, 'placed', pl,
        'cv_to_first_interview_pct', round(fi::numeric/nullif(cv,0),3),
        'cv_to_placed_pct', round(pl::numeric/nullif(cv,0),3)) order by cv desc), '[]'::jsonb) from per)
  );
$function$;

-- Lock down: only the service role (used by the MCP edge function) may execute.
revoke all on function public.funnel_report(date, date, text, text) from public, anon, authenticated;
grant execute on function public.funnel_report(date, date, text, text) to service_role;
