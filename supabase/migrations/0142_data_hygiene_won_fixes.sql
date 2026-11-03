-- 0142_data_hygiene_won_fixes.sql
-- octagon-mcp 3.96.0 lets update_deal (/won) set a deal's annual salary, fee % and start date, so the
-- data_hygiene fixes for those three checks now point at /won instead of RecruitCRM. Function body is
-- otherwise unchanged from 0141.

create or replace function public.data_hygiene(p_from date default null, p_to date default null, p_consultant text default null, p_items int default 25)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with w as (
    -- No default end: a Won deal dated later in the quarter is still a record with gaps.
    select coalesce(p_from, date '2026-01-01') f, coalesce(p_to, 'infinity'::date) t,
      greatest(coalesce(p_items, 25), 1) n
  ),
  who as (select id, recruitcrm_id, name, (coalesce(active, true) and deleted_at is null) active from consultants),
  won as (
    select d.*, cl.company_name client, o.name owner, o.active owner_active
    from deals d left join clients cl on cl.company_slug = d.company_slug left join who o on o.recruitcrm_id = d.owner_recruitcrm_id, w
    where d.deleted_at is null and d.deal_stage = 'Won' and d.close_date >= w.f and d.close_date < w.t
      and (p_consultant is null or o.name ilike '%' || p_consultant || '%')
  ),
  won_rows as (
    select won.*, jsonb_build_object('deal', deal_name, 'client', client, 'closed', close_date, 'value', deal_value,
      'salary', annual_salary, 'fee_pct', fee_percentage, 'start_date', start_date, 'owner', owner, 'owner_left', not coalesce(owner_active, true),
      'suggested_fee_pct', case when coalesce(fee_percentage, 0) = 0 and annual_salary > 0 and deal_value > 0
                               then round(deal_value / annual_salary * 100, 1) end) j
    from won
  ),
  live_jobs as (
    select j.slug, j.recruitcrm_id, j.title, j.status, j.created_date, cl.company_name client, o.name owner, o.active owner_active
    from jobs j left join clients cl on cl.id = j.client_id left join who o on o.id = j.consultant_id
    where j.deleted_at is null and j.status in ('Open', 'On Hold')
  ),
  latest as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, e.candidate_name, e.job_slug, e.stage_metric, e.event_date
    from candidate_stage_events e order by e.candidate_slug, e.job_slug, e.event_timestamp desc
  ),
  placed as (
    select distinct on (e.candidate_slug, e.job_slug) e.candidate_slug, coalesce(e.candidate_name, e.candidate_slug) candidate, e.job_slug,
      e.event_date, j.title job, cl.company_name client, o.name owner
    from candidate_stage_events e join jobs j on j.slug = e.job_slug left join clients cl on cl.id = j.client_id left join who o on o.id = j.consultant_id, w
    where e.stage_metric = 'placed' and e.event_date >= w.f and e.event_date < w.t
      and not exists (select 1 from deals d where d.deleted_at is null and d.job_slug = e.job_slug and d.deal_stage = 'Won')
      and (p_consultant is null or o.name ilike '%' || p_consultant || '%')
    order by e.candidate_slug, e.job_slug, e.event_date desc
  ),
  offered as (
    select coalesce(l.candidate_name, l.candidate_slug) candidate, l.event_date, lj.title job, lj.client, lj.owner
    from latest l join live_jobs lj on lj.slug = l.job_slug
    where l.stage_metric = 'offered'
      and not exists (select 1 from deals d where d.deleted_at is null and d.job_slug = l.job_slug)
      and (p_consultant is null or lj.owner ilike '%' || p_consultant || '%')
  ),
  leaver_jobs as (
    select * from live_jobs where owner is not null and not owner_active
      and (p_consultant is null or owner ilike '%' || p_consultant || '%')
  ),
  no_client as (
    select j.recruitcrm_id, j.title, j.status, j.created_date, o.name owner
    from jobs j left join who o on o.id = j.consultant_id
    where j.deleted_at is null and j.client_id is null and (p_consultant is null or o.name ilike '%' || p_consultant || '%')
  ),
  untagged as (
    select a.consultant, count(*) n
    from call_activity a
    where a.call_date >= (now() at time zone 'Europe/London')::date - 7 and coalesce(a.custom_call_type, '') = ''
      and coalesce(a.duration_seconds, 0) >= 30 and (p_consultant is null or a.consultant ilike '%' || p_consultant || '%')
    group by 1
  ),
  checks as (
    select 1 ord, 'won_no_fee_pct' k, 'Won deals with no fee %' label, 'Set it with /won (fee_pct); suggested_fee_pct is value / salary, to confirm with the recruiter first.' fix,
      (select count(*) from won_rows where coalesce(fee_percentage, 0) = 0) n,
      (select jsonb_agg(j order by close_date desc) from (select * from won_rows where coalesce(fee_percentage, 0) = 0 order by close_date desc limit (select n from w)) x) items
    union all select 2, 'won_no_salary', 'Won deals with no annual salary', 'Set it with /won (salary).',
      (select count(*) from won_rows where coalesce(annual_salary, 0) = 0),
      (select jsonb_agg(j order by close_date desc) from (select * from won_rows where coalesce(annual_salary, 0) = 0 order by close_date desc limit (select n from w)) x)
    union all select 3, 'won_no_value', 'Won deals with no value (billing counts them as £0)', 'Enter the fee with /won.',
      (select count(*) from won_rows where coalesce(deal_value, 0) = 0),
      (select jsonb_agg(j) from (select * from won_rows where coalesce(deal_value, 0) = 0 limit (select n from w)) x)
    union all select 4, 'won_no_start_date', 'Won deals with no start date (aftercare cannot see them)', 'Set it with /won (start_date).',
      (select count(*) from won_rows where start_date is null),
      (select jsonb_agg(j) from (select * from won_rows where start_date is null limit (select n from w)) x)
    union all select 5, 'won_no_job', 'Won deals not linked to a job', 'Link the deal to its job in RecruitCRM.',
      (select count(*) from won_rows where job_slug is null),
      (select jsonb_agg(j) from (select * from won_rows where job_slug is null limit (select n from w)) x)
    union all select 6, 'placed_no_won_deal', 'Placed candidates with no Won deal on the job (unbilled)', 'Create the deal with /newdeal, then mark it Won with /won.',
      (select count(*) from placed),
      (select jsonb_agg(jsonb_build_object('candidate', candidate, 'job', job, 'client', client, 'placed_on', event_date, 'owner', owner)) from (select * from placed order by event_date desc limit (select n from w)) x)
    union all select 7, 'offered_no_deal', 'Candidates at Offered with no deal on the job', 'Create the deal at Offered with /newdeal so the pipeline counts it.',
      (select count(*) from offered),
      (select jsonb_agg(jsonb_build_object('candidate', candidate, 'job', job, 'client', client, 'offered_on', event_date, 'owner', owner)) from (select * from offered order by event_date limit (select n from w)) x)
    union all select 8, 'live_jobs_leaver', 'Open and On Hold jobs owned by a leaver', 'Move them with /handover.',
      (select count(*) from leaver_jobs),
      (select jsonb_agg(jsonb_build_object('job_id', recruitcrm_id, 'title', title, 'client', client, 'status', status, 'owner', owner)) from (select * from leaver_jobs order by owner, created_date desc limit (select n from w)) x)
    union all select 9, 'jobs_no_client', 'Jobs with no client', 'Set the company on the job in RecruitCRM.',
      (select count(*) from no_client),
      (select jsonb_agg(jsonb_build_object('job_id', recruitcrm_id, 'title', title, 'status', status, 'opened', created_date::date, 'owner', owner)) from (select * from no_client order by created_date desc limit (select n from w)) x)
    union all select 10, 'untagged_calls_7d', 'Calls of 30s or more in the last 7 days with no call type', 'Tag them with /tagcalls so they count toward the weekly call targets.',
      (select coalesce(sum(n), 0) from untagged),
      (select jsonb_agg(jsonb_build_object('caller', coalesce(consultant, 'Unknown'), 'calls', n) order by n desc) from untagged)
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', (select f from w), 'to_exclusive', (select case when isfinite(t) then t end from w)),
    'scope', coalesce(p_consultant, 'Whole firm'),
    'definition', 'Record gaps that make fee, billing, desk and call figures wrong. Deals are attributed to the deal owner, jobs and candidates to the job owner, calls to the caller. Won deals and placements are counted by close or placed date in the window; jobs and calls are as of today. Items are capped per check; count is the full number.',
    'won_deals_in_window', (select count(*) from won),
    'issues_total', (select sum(n) from checks),
    'checks', (select jsonb_agg(jsonb_build_object('check', k, 'label', label, 'count', n, 'fix', fix, 'items', coalesce(items, '[]'::jsonb)) order by (n = 0), ord) from checks)
  );
$function$;
revoke execute on function public.data_hygiene(date, date, text, int) from public, anon, authenticated;
