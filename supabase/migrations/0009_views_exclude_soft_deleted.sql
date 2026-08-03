-- 0009_views_exclude_soft_deleted.sql
-- Cleanup: make the semantic views ignore soft-deleted (deleted_at) clients /
-- consultants. Added to the LEFT JOIN conditions so a deleted match falls
-- through to 'Unknown Client'/NULL rather than dropping the row's activity.
-- (No behavioural change today — nothing is soft-deleted yet — but correct once
-- the nightly reconcile starts flagging departures.)

create or replace view public.client_funnel with (security_invoker = on) as
with deal_per_job as (
  select distinct on (job_slug) job_slug, company_slug
  from public.deals where job_slug is not null
  order by job_slug, created_date
)
select
  coalesce(c.company_name, 'Unknown Client') as client_name,
  count(distinct e.job_slug) as active_jobs,
  count(*) filter (where e.stage_metric = 'cv_sent') as cv_sent,
  count(*) filter (where e.stage_metric = 'interview_request') as interview_requests,
  count(*) filter (where e.stage_metric = 'first_interview') as first_interviews,
  count(*) filter (where e.stage_metric = 'second_interview') as second_interviews,
  count(*) filter (where e.stage_metric = 'offered') as offers,
  count(*) filter (where e.stage_metric = 'placed') as placements
from public.v_candidate_events e
left join deal_per_job d on e.job_slug = d.job_slug
left join public.clients c on d.company_slug = c.company_slug and c.deleted_at is null
group by coalesce(c.company_name, 'Unknown Client');

create or replace view public.client_revenue with (security_invoker = on) as
select
  coalesce(cl.company_name, 'Unknown Client') as company_name,
  count(*) filter (where d.deal_stage = 'Won') as won_deals,
  sum(d.deal_value) filter (where d.deal_stage = 'Won') as won_revenue,
  sum(d.deal_value) filter (where d.deal_stage not in ('Won','Lost')) as open_pipeline,
  avg(d.deal_value) as average_deal_value
from public.deals d
left join public.clients cl on d.company_slug = cl.company_slug and cl.deleted_at is null
group by coalesce(cl.company_name, 'Unknown Client')
order by sum(d.deal_value) filter (where d.deal_stage = 'Won') desc nulls last;

create or replace view public.consultant_pipeline with (security_invoker = on) as
select
  c.name as consultant_name,
  count(d.id) as total_deals,
  sum(d.deal_value) filter (where d.deal_stage not in ('Won','Lost')) as open_pipeline,
  sum(d.deal_value) filter (where d.deal_stage = 'Won') as won_revenue,
  avg(d.deal_value) as average_deal_value
from public.deals d
left join public.consultants c on d.owner_recruitcrm_id = c.recruitcrm_id and c.deleted_at is null
group by c.name
order by sum(d.deal_value) filter (where d.deal_stage not in ('Won','Lost')) desc nulls last;

create or replace view public.job_pipeline with (security_invoker = on) as
with deal_per_job as (
  select distinct on (job_slug) job_slug, deal_name, company_slug, deal_value, deal_stage, close_date, created_date
  from public.deals order by job_slug, created_date
)
select
  d.job_slug, d.deal_name,
  coalesce(c.company_name, 'Unknown Client') as client_name,
  coalesce(mode() within group (order by e.consultant_name), 'Unassigned') as consultant_name,
  d.deal_value, d.deal_stage, d.close_date as target_close_date,
  current_date - d.created_date::date as days_open,
  count(*) filter (where e.stage_metric = 'cv_sent') as cv_sent,
  count(*) filter (where e.stage_metric = 'offered') as offers,
  count(*) filter (where e.stage_metric = 'placed') as placements,
  count(distinct e.candidate_id) as unique_candidates
from deal_per_job d
left join public.v_candidate_events e on d.job_slug = e.job_slug
left join public.clients c on d.company_slug = c.company_slug and c.deleted_at is null
group by d.job_slug, d.deal_name, c.company_name, d.deal_value, d.deal_stage, d.close_date, d.created_date;
