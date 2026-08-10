-- 0046_rejection_and_fee_analysis.sql
-- Two datasets that were already in the mirror but that no report could reach.
--
-- 1. rejection_report() — rejected_consultant (6,023 events) and rejected_client (3,853) have been
--    recording since 2019 and appeared in no tool. The useful ratio is rejected_client / cv_sent:
--    of the CVs we put in front of a client, what share came back rejected. High = we're sending
--    the wrong people or briefing the role badly. Owner-attributed, like the rest of the funnel.
--
-- 2. fee_analysis() — the components landed by 0043 (annual_salary, fee_percentage) plus
--    jobs.forecast_fee had nothing exposing them. Gives average and median fee, the fee percentage
--    actually achieved, the salary band being placed, and forecast fee on open roles.
--    Deal-owner-attributed, matching how billing works.
--
-- Both quote MEDIANS alongside averages, and fee_analysis excludes fee_percentage values above 100
-- from the percentage stats (two rows carry data-entry errors, one reading 7000) while reporting
-- how many were excluded — an average of 34.4% against a true median of 18.0% is exactly the sort
-- of thing that gets quoted at a client.

create or replace function public.rejection_report(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_consultant text default null, p_limit int default 20)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with ev as (
    select e.stage_metric, co.name consultant, cl.company_name client
    from candidate_stage_events e
    join jobs j on e.job_slug = j.slug and j.deleted_at is null
    left join consultants co on j.consultant_id = co.id and co.deleted_at is null
    left join clients cl on j.client_id = cl.id and cl.deleted_at is null
    where e.event_date >= p_from and e.event_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  ),
  by_c as (
    select consultant,
      count(*) filter (where stage_metric='cv_sent') cv,
      count(*) filter (where stage_metric='rejected_client') rc,
      count(*) filter (where stage_metric='rejected_consultant') rr
    from ev where consultant is not null group by consultant
  ),
  by_cl as (
    select client,
      count(*) filter (where stage_metric='cv_sent') cv,
      count(*) filter (where stage_metric='rejected_client') rc
    from ev where client is not null group by client
  )
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Rejections from candidate_stage_events, attributed to the job owner. rejected_by_client = the client turned the candidate down; rejected_by_consultant = we screened them out ourselves. client_rejection_rate_pct = rejected_by_client / cv_sent as a percentage to 1dp — a candidate can be rejected without a CV send having been logged in the same window, so the rate can exceed 100% at the edges.',
    'totals', (select jsonb_build_object(
        'cv_sent', count(*) filter (where stage_metric='cv_sent'),
        'rejected_by_client', count(*) filter (where stage_metric='rejected_client'),
        'rejected_by_consultant', count(*) filter (where stage_metric='rejected_consultant'),
        'client_rejection_rate_pct', round(100*(count(*) filter (where stage_metric='rejected_client'))::numeric
          / nullif(count(*) filter (where stage_metric='cv_sent'),0), 1)) from ev),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'cv_sent', cv, 'rejected_by_client', rc, 'rejected_by_consultant', rr,
        'client_rejection_rate_pct', round(100*rc::numeric/nullif(cv,0),1)) order by rc desc), '[]'::jsonb)
      from (select * from by_c order by rc desc limit p_limit) x),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object(
        'client', client, 'cv_sent', cv, 'rejected_by_client', rc,
        'client_rejection_rate_pct', round(100*rc::numeric/nullif(cv,0),1)) order by rc desc), '[]'::jsonb)
      from (select * from by_cl order by rc desc limit p_limit) y)
  );
$function$;

create or replace function public.fee_analysis(
  p_from date default '2026-01-01', p_to date default '2100-01-01',
  p_consultant text default null, p_limit int default 20)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with d as (
    select dl.deal_value, dl.annual_salary, dl.fee_percentage, co.name consultant
    from deals dl
    left join consultants co on co.recruitcrm_id = dl.owner_recruitcrm_id and co.deleted_at is null
    where dl.deal_stage = 'Won' and dl.recruitcrm_id is not null
      and dl.close_date >= p_from and dl.close_date < p_to
      and (p_consultant is null or co.name ilike '%'||p_consultant||'%')
  ),
  -- Percentage stats only from plausible values; the excluded count is reported, never hidden.
  pct as (select fee_percentage p from d where fee_percentage is not null and fee_percentage <= 100),
  sal as (select annual_salary s from d where annual_salary is not null and annual_salary > 0)
  select jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'definition', 'Won deals in the window, attributed to the deal owner. The fee IS deal_value; annual_salary and fee_percentage are the RecruitCRM custom fields behind it (deal_value = salary x percentage / 100). Medians are the figure to quote — a couple of deals carry a mistyped percentage. forecast_open_roles is the sum of the Forecast Fee custom field across all currently open jobs and is not window-scoped.',
    'totals', (select jsonb_build_object(
        'won_deals', count(*),
        'fee_total', round(coalesce(sum(deal_value),0),2),
        'fee_avg', round(avg(deal_value)),
        'fee_median', round((percentile_cont(0.5) within group (order by deal_value))::numeric),
        'deals_with_components', count(*) filter (where annual_salary is not null and fee_percentage is not null)) from d),
    'fee_percentage', (select jsonb_build_object(
        'median', round((percentile_cont(0.5) within group (order by p))::numeric,1),
        'p25', round((percentile_cont(0.25) within group (order by p))::numeric,1),
        'p75', round((percentile_cont(0.75) within group (order by p))::numeric,1),
        'sample', count(*),
        'excluded_over_100', (select count(*) from d where fee_percentage > 100)) from pct),
    'annual_salary', (select jsonb_build_object(
        'median', round((percentile_cont(0.5) within group (order by s))::numeric),
        'p25', round((percentile_cont(0.25) within group (order by s))::numeric),
        'p75', round((percentile_cont(0.75) within group (order by s))::numeric),
        'sample', count(*)) from sal),
    'by_consultant', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', consultant, 'won_deals', n, 'fee_total', ft, 'fee_median', fm, 'fee_pct_median', pm) order by ft desc), '[]'::jsonb)
      from (select consultant, count(*) n, round(coalesce(sum(deal_value),0),2) ft,
              round((percentile_cont(0.5) within group (order by deal_value))::numeric) fm,
              round((percentile_cont(0.5) within group (order by fee_percentage) filter (where fee_percentage <= 100))::numeric,1) pm
            from d where consultant is not null group by consultant order by 3 desc limit p_limit) z),
    'forecast_open_roles', (select round(coalesce(sum(forecast_fee),0),2) from jobs
      where deleted_at is null and status ilike '%open%')
  );
$function$;

revoke all on function public.rejection_report(date,date,text,int) from public, anon, authenticated;
grant execute on function public.rejection_report(date,date,text,int) to service_role;
revoke all on function public.fee_analysis(date,date,text,int) from public, anon, authenticated;
grant execute on function public.fee_analysis(date,date,text,int) to service_role;
