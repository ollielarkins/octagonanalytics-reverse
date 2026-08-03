-- 0002_canonical_semantic_layer.sql
-- Rebuild the semantic layer canonically (see docs/DECISIONS.md D1–D7).
--
-- Strategy:
--   1. Preserve the 19 hand-built views by moving them to a non-public `legacy`
--      schema — an executable rollback, and it removes them from the PostgREST
--      API surface (clearing the 19 security_definer_view errors).
--   2. Build ONE canonical set in public, all security_invoker, all funnel metrics
--      derived from a single base view `v_candidate_events` where the reporting
--      exclusion (D3) and consultant resolution (D7) are applied exactly once —
--      making "two views disagree" structurally impossible.
--   3. Deals-based pipeline/revenue kept explicitly separate from the funnel (D5),
--      and daily_activity kept as a separate, clearly-labelled reported fact (D1).

-- ── 1. Stash legacy views ───────────────────────────────────────────────────────
create schema if not exists legacy;
do $$
declare v text;
begin
  for v in
    select table_name from information_schema.views where table_schema = 'public'
  loop
    execute format('alter view public.%I set schema legacy;', v);
  end loop;
end $$;

-- ── 2. Canonical base view: the single funnel source (D1, D2, D3, D7) ────────────
create view public.v_candidate_events with (security_invoker = on) as
select
  cse.event_date,
  cse.event_timestamp,
  cse.consultant                              as consultant_name,   -- display (D7)
  cse.consultant_id                           as consultant_recruitcrm_id,
  con.team,
  cse.candidate_id,
  cse.candidate_name,
  cse.job_slug,
  cse.job_title,
  cse.stage_metric,                                                 -- canonical (D2)
  cse.stage_name                                                    -- display (D2)
from public.candidate_stage_events cse
left join public.consultants con
  on con.recruitcrm_id = cse.consultant_id                          -- resolve on id (D7)
where not exists (                                                  -- exclusion once (D3)
  select 1 from public.reporting_exclusions re
  where re.consultant_name = cse.consultant
);
comment on view public.v_candidate_events is
  'Canonical funnel source: candidate_stage_events with reporting exclusions applied once and consultant resolved on recruitcrm_id. Every funnel metric derives from here.';

-- Helper macro note: stage counts use FILTER on stage_metric throughout.

-- ── 3. Consultant funnel (replaces consultant_stage_summary,
--      consultant_stage_funnel_ratios, consultant_conversion_ratios) ──────────────
create view public.consultant_funnel with (security_invoker = on) as
select
  consultant_name,
  count(*) filter (where stage_metric = 'cv_sent')           as cv_sent,
  count(*) filter (where stage_metric = 'interview_request') as interview_request,
  count(*) filter (where stage_metric = 'first_interview')   as first_interview,
  count(*) filter (where stage_metric = 'second_interview')  as second_interview,
  count(*) filter (where stage_metric = 'offered')           as offered,
  count(*) filter (where stage_metric = 'placed')            as placed,
  round(count(*) filter (where stage_metric = 'interview_request')::numeric
        / nullif(count(*) filter (where stage_metric = 'cv_sent'), 0), 3)  as cv_to_interview_pct,
  round(count(*) filter (where stage_metric = 'first_interview')::numeric
        / nullif(count(*) filter (where stage_metric = 'interview_request'), 0), 3) as interview_to_first_pct,
  round(count(*) filter (where stage_metric = 'offered')::numeric
        / nullif(count(*) filter (where stage_metric = 'first_interview'), 0), 3) as first_to_offer_pct,
  round(count(*) filter (where stage_metric = 'placed')::numeric
        / nullif(count(*) filter (where stage_metric = 'offered'), 0), 3)  as offer_to_placed_pct
from public.v_candidate_events
group by consultant_name;

-- ── 4. Consultant activity by day / week / month ────────────────────────────────
create view public.consultant_activity_daily with (security_invoker = on) as
select
  event_date,
  consultant_name,
  count(*) filter (where stage_metric = 'cv_sent')            as cv_sent,
  count(*) filter (where stage_metric = 'interview_request')  as interview_request,
  count(*) filter (where stage_metric = 'first_interview')    as first_interview,
  count(*) filter (where stage_metric = 'second_interview')   as second_interview,
  count(*) filter (where stage_metric = 'offered')            as offered,
  count(*) filter (where stage_metric = 'placed')             as placed,
  count(*) filter (where stage_metric = 'rejected_consultant') as rejected_consultant,
  count(*) filter (where stage_metric = 'rejected_client')    as rejected_client
from public.v_candidate_events
where event_date is not null
group by event_date, consultant_name;

create view public.consultant_activity_monthly with (security_invoker = on) as
with m as (
  select
    date_trunc('month', event_date::timestamp)::date as month_start,
    consultant_name,
    count(*) filter (where stage_metric = 'cv_sent')           as cv_sent,
    count(*) filter (where stage_metric = 'interview_request') as interview_request,
    count(*) filter (where stage_metric = 'first_interview')   as first_interview,
    count(*) filter (where stage_metric = 'second_interview')  as second_interview,
    count(*) filter (where stage_metric = 'offered')           as offered,
    count(*) filter (where stage_metric = 'placed')            as placed
  from public.v_candidate_events
  where event_date is not null
  group by 1, 2
)
select *,
  round(interview_request::numeric / nullif(cv_sent,0), 4)     as cv_to_interview_conversion,
  round(first_interview::numeric   / nullif(interview_request,0), 4) as interview_to_first_conversion,
  round(offered::numeric           / nullif(first_interview,0), 4)   as first_to_offer_conversion,
  round(placed::numeric            / nullif(offered,0), 4)     as offer_to_placed_conversion
from m;

-- ── 5. Firm-wide monthly summary with MoM (replaces team_summary_report +
--      activity_trends_weekly_report) ──────────────────────────────────────────────
create view public.team_summary_monthly with (security_invoker = on) as
with m as (
  select
    date_trunc('month', event_date::timestamp)::date as month_start,
    count(*) filter (where stage_metric = 'cv_sent')  as cv_sent,
    count(*) filter (where stage_metric = 'offered')  as offered,
    count(*) filter (where stage_metric = 'placed')   as placed,
    count(distinct consultant_name)                   as active_consultants
  from public.v_candidate_events
  where event_date is not null
  group by 1
)
select *,
  round((cv_sent - lag(cv_sent) over (order by month_start))::numeric
        / nullif(lag(cv_sent) over (order by month_start),0) * 100, 2) as cv_sent_mom_pct,
  round((placed - lag(placed) over (order by month_start))::numeric
        / nullif(lag(placed) over (order by month_start),0) * 100, 2)  as placed_mom_pct,
  round(placed::numeric / nullif(cv_sent,0), 4)                        as cv_to_placed_conversion
from m
order by month_start desc;

-- ── 6. Consultant rankings (replaces consultant_rankings_report) ─────────────────
create view public.consultant_rankings with (security_invoker = on) as
with cm as (
  select
    consultant_name,
    count(*) filter (where stage_metric = 'cv_sent') as cv_sent,
    count(*) filter (where stage_metric in ('interview_request','first_interview','second_interview')) as interviews,
    count(*) filter (where stage_metric = 'offered') as offers,
    count(*) filter (where stage_metric = 'placed')  as placements
  from public.v_candidate_events
  group by consultant_name
),
r as (
  select *,
    row_number() over (order by cv_sent desc)    as rank_by_cv_sent,
    row_number() over (order by interviews desc) as rank_by_interviews,
    row_number() over (order by offers desc)     as rank_by_offers,
    row_number() over (order by placements desc) as rank_by_placements
  from cm
)
select *,
  round((rank_by_cv_sent + rank_by_interviews + rank_by_offers + rank_by_placements)::numeric / 4, 2) as overall_rank_score
from r
order by overall_rank_score, consultant_name;

-- ── 7. Stage timing (replaces stage_timing_analysis_report) ──────────────────────
create view public.stage_timing with (security_invoker = on) as
with firsts as (
  select consultant_name, candidate_id, job_slug, stage_metric, min(event_date) as stage_date
  from public.v_candidate_events
  group by consultant_name, candidate_id, job_slug, stage_metric
),
pivoted as (
  select consultant_name, candidate_id, job_slug,
    max(stage_date) filter (where stage_metric = 'cv_sent')           as cv_date,
    max(stage_date) filter (where stage_metric = 'interview_request') as int_req_date,
    max(stage_date) filter (where stage_metric = 'first_interview')   as first_int_date,
    max(stage_date) filter (where stage_metric = 'offered')           as offer_date,
    max(stage_date) filter (where stage_metric = 'placed')            as placed_date
  from firsts
  group by consultant_name, candidate_id, job_slug
),
transitions as (
  select consultant_name, 'CV Sent → Interview Request' as transition, 1 as sort_order,
         int_req_date - cv_date as days
  from pivoted where cv_date is not null and int_req_date is not null and int_req_date >= cv_date
  union all
  select consultant_name, 'Interview Request → 1st Interview', 2, first_int_date - int_req_date
  from pivoted where int_req_date is not null and first_int_date is not null and first_int_date >= int_req_date
  union all
  select consultant_name, '1st Interview → Offer', 3, offer_date - first_int_date
  from pivoted where first_int_date is not null and offer_date is not null and offer_date >= first_int_date
  union all
  select consultant_name, 'Offer → Placement', 4, placed_date - offer_date
  from pivoted where offer_date is not null and placed_date is not null and placed_date >= offer_date
)
select consultant_name, transition, sort_order,
  count(*)::int as candidate_count,
  round(avg(days))::int as avg_days,
  percentile_cont(0.5) within group (order by days::float)::int as median_days,
  min(days) as min_days, max(days) as max_days
from transitions
group by consultant_name, transition, sort_order
order by consultant_name, sort_order;

-- ── 8. Client funnel (replaces client_dashboard_report) ──────────────────────────
create view public.client_funnel with (security_invoker = on) as
select
  coalesce(c.company_name, 'Unknown Client') as client_name,
  count(distinct e.job_slug)                 as active_jobs,
  count(*) filter (where e.stage_metric = 'cv_sent')           as cv_sent,
  count(*) filter (where e.stage_metric = 'interview_request') as interview_requests,
  count(*) filter (where e.stage_metric = 'first_interview')   as first_interviews,
  count(*) filter (where e.stage_metric = 'second_interview')  as second_interviews,
  count(*) filter (where e.stage_metric = 'offered')           as offers,
  count(*) filter (where e.stage_metric = 'placed')            as placements
from public.v_candidate_events e
left join public.deals d   on e.job_slug = d.job_slug
left join public.clients c on d.company_slug = c.company_slug
group by coalesce(c.company_name, 'Unknown Client');

-- ── 9. Job pipeline (replaces job_pipeline_report) ───────────────────────────────
create view public.job_pipeline with (security_invoker = on) as
with deal_per_job as (
  select distinct on (job_slug)
    job_slug, deal_name, company_slug, deal_value, deal_stage, close_date, created_date
  from public.deals
  order by job_slug, created_date
)
select
  d.job_slug, d.deal_name,
  coalesce(c.company_name, 'Unknown Client') as client_name,
  coalesce(mode() within group (order by e.consultant_name), 'Unassigned') as consultant_name,
  d.deal_value, d.deal_stage, d.close_date as target_close_date,
  current_date - d.created_date::date as days_open,
  count(*) filter (where e.stage_metric = 'cv_sent')          as cv_sent,
  count(*) filter (where e.stage_metric = 'offered')          as offers,
  count(*) filter (where e.stage_metric = 'placed')           as placements,
  count(distinct e.candidate_id)                              as unique_candidates
from deal_per_job d
left join public.v_candidate_events e on d.job_slug = e.job_slug
left join public.clients c on d.company_slug = c.company_slug
group by d.job_slug, d.deal_name, c.company_name, d.deal_value, d.deal_stage, d.close_date, d.created_date;

-- ── 10. Deals: pipeline vs revenue, explicitly separated (D5) ────────────────────
-- NOTE (D5): 'Won'/'Lost' are ASSUMPTIONS for deal_stage until the real RecruitCRM
-- values are confirmed. Adjust these three views once known.
create view public.deal_pipeline_by_stage with (security_invoker = on) as
select deal_stage, count(*) as total_deals, sum(deal_value) as total_value
from public.deals
where deal_stage is distinct from 'Won' and deal_stage is distinct from 'Lost'  -- open only
group by deal_stage
order by sum(deal_value) desc nulls last;

create view public.pipeline_monthly with (security_invoker = on) as
select date_trunc('month', created_date)::date as month, sum(deal_value) as total_pipeline, count(*) as total_deals
from public.deals
where deal_stage is distinct from 'Won' and deal_stage is distinct from 'Lost'
group by 1 order by 1;

create view public.revenue_monthly with (security_invoker = on) as
select date_trunc('month', close_date)::date as month,  -- bucket by close_date, not created (D5)
       sum(deal_value) as total_revenue, count(*) as total_deals
from public.deals
where deal_stage = 'Won'
group by 1 order by 1;

create view public.client_revenue with (security_invoker = on) as
select
  coalesce(cl.company_name, 'Unknown Client') as company_name,
  count(*) filter (where d.deal_stage = 'Won')                          as won_deals,
  sum(d.deal_value) filter (where d.deal_stage = 'Won')                 as won_revenue,
  sum(d.deal_value) filter (where d.deal_stage not in ('Won','Lost'))   as open_pipeline,
  avg(d.deal_value)                                                     as average_deal_value
from public.deals d
left join public.clients cl on d.company_slug = cl.company_slug
group by coalesce(cl.company_name, 'Unknown Client')
order by won_revenue desc nulls last;

create view public.consultant_pipeline with (security_invoker = on) as
select
  c.name as consultant_name,
  count(d.id) as total_deals,
  sum(d.deal_value) filter (where d.deal_stage not in ('Won','Lost')) as open_pipeline,
  sum(d.deal_value) filter (where d.deal_stage = 'Won')               as won_revenue,
  avg(d.deal_value) as average_deal_value
from public.deals d
left join public.consultants c on d.owner_recruitcrm_id = c.recruitcrm_id  -- resolve on id (D7)
group by c.name
order by open_pipeline desc nulls last;

-- ── 11. daily_activity kept as a separate, clearly-labelled reported fact (D1) ────
create view public.reported_activity_daily with (security_invoker = on) as
select
  activity_date, consultant,
  sum(tasks_added) as tasks_added, sum(jobs_added) as jobs_added, sum(assigned) as assigned,
  sum(cv_sent) as cv_sent, sum(interview_request) as interview_request,
  sum(first_interview) as first_interview, sum(second_interview) as second_interview,
  sum(offered) as offered, sum(prospect_bd) as prospect_bd, sum(client) as client,
  sum(internal_interview) as internal_interview, sum(job_order_form_complete) as job_order_form_complete,
  sum(lead) as lead, sum(pitched) as pitched, sum(call_time_minutes) as call_time_minutes
from public.daily_activity
group by activity_date, consultant;
comment on view public.reported_activity_daily is
  'SEPARATE SOURCE (D1): pre-aggregated daily_activity import of unconfirmed provenance. NOT the funnel source of truth; do not sum with candidate_stage_events-derived counts.';
