-- 0003_review_fixes.sql
-- Fixes from the post-build review (2026-08-03), validated against real data.

-- Fix A (correctness): client_funnel double-counted candidate events for any
-- job_slug that appears on more than one deal row (found: 91 deals / 90 distinct
-- job_slug). Dedup deals to one row per job_slug before joining, matching the
-- pattern already used in job_pipeline.
create or replace view public.client_funnel with (security_invoker = on) as
with deal_per_job as (
  select distinct on (job_slug) job_slug, company_slug
  from public.deals
  where job_slug is not null
  order by job_slug, created_date
)
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
left join deal_per_job d   on e.job_slug = d.job_slug
left join public.clients c on d.company_slug = c.company_slug
group by coalesce(c.company_name, 'Unknown Client');

-- Fix B (hardening): the stashed legacy views are still SECURITY DEFINER. They
-- are not reachable via the API (legacy schema isn't exposed), but revoke access
-- from the client roles for defence in depth.
revoke all on all tables in schema legacy from anon, authenticated;
revoke usage on schema legacy from anon, authenticated;
